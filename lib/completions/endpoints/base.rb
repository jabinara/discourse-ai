# frozen_string_literal: true

module DiscourseAi
  module Completions
    module Endpoints
      class Base
        attr_reader :partial_tool_calls

        CompletionFailed = Class.new(StandardError)
        # 6 minutes
        # Reasoning LLMs can take a very long time to respond, generally it will be under 5 minutes
        # The alternative is to have per LLM timeouts but that would make it extra confusing for people
        # configuring. Let's try this simple solution first.
        TIMEOUT = 360

        class << self
          def endpoint_for(provider_name)
            endpoints = [
              DiscourseAi::Completions::Endpoints::AwsBedrock,
              DiscourseAi::Completions::Endpoints::OpenAi,
              DiscourseAi::Completions::Endpoints::HuggingFace,
              DiscourseAi::Completions::Endpoints::Gemini,
              DiscourseAi::Completions::Endpoints::Vllm,
              DiscourseAi::Completions::Endpoints::Anthropic,
              DiscourseAi::Completions::Endpoints::Cohere,
              DiscourseAi::Completions::Endpoints::SambaNova,
              DiscourseAi::Completions::Endpoints::Mistral,
              DiscourseAi::Completions::Endpoints::OpenRouter,
            ]

            endpoints << DiscourseAi::Completions::Endpoints::Ollama if Rails.env.development?

            if Rails.env.test? || Rails.env.development?
              endpoints << DiscourseAi::Completions::Endpoints::Fake
            end

            endpoints.detect(-> { raise DiscourseAi::Completions::Llm::UNKNOWN_MODEL }) do |ek|
              ek.can_contact?(provider_name)
            end
          end

          def can_contact?(_model_provider)
            raise NotImplementedError
          end
        end

        def initialize(llm_model)
          @llm_model = llm_model
        end

        def use_ssl?
          if model_uri&.scheme.present?
            model_uri.scheme == "https"
          else
            true
          end
        end

        def xml_tags_to_strip(dialect)
          []
        end

        def perform_completion!(
          dialect,
          user,
          model_params = {},
          feature_name: nil,
          feature_context: nil,
          partial_tool_calls: false,
          &blk
        )
          LlmQuota.check_quotas!(@llm_model, user)
          start_time = Time.now

          @partial_tool_calls = partial_tool_calls
          model_params = normalize_model_params(model_params)
          orig_blk = blk

          if block_given? && disable_streaming?
            result =
              perform_completion!(
                dialect,
                user,
                model_params,
                feature_name: feature_name,
                feature_context: feature_context,
                partial_tool_calls: partial_tool_calls,
              )

            wrapped = result
            wrapped = [result] if !result.is_a?(Array)
            cancelled_by_caller = false
            cancel_proc = -> { cancelled_by_caller = true }
            wrapped.each do |partial|
              blk.call(partial, cancel_proc)
              break if cancelled_by_caller
            end
            return result
          end

          @streaming_mode = block_given?

          prompt = dialect.translate

          FinalDestination::HTTP.start(
            model_uri.host,
            model_uri.port,
            use_ssl: use_ssl?,
            read_timeout: TIMEOUT,
            open_timeout: TIMEOUT,
            write_timeout: TIMEOUT,
          ) do |http|
            response_data = +""
            response_raw = +""

            # Needed to response token calculations. Cannot rely on response_data due to function buffering.
            partials_raw = +""
            request_body = prepare_payload(prompt, model_params, dialect).to_json

            request = prepare_request(request_body)

            http.request(request) do |response|
              if response.code.to_i != 200
                Rails.logger.error(
                  "#{self.class.name}: status: #{response.code.to_i} - body: #{response.body}",
                )
                raise CompletionFailed, response.body
              end

              xml_tool_processor =
                XmlToolProcessor.new(
                  partial_tool_calls: partial_tool_calls,
                ) if xml_tools_enabled? && dialect.prompt.has_tools?

              to_strip = xml_tags_to_strip(dialect)
              xml_stripper =
                DiscourseAi::Completions::XmlTagStripper.new(to_strip) if to_strip.present?

              if @streaming_mode && xml_stripper
                blk =
                  lambda do |partial, cancel|
                    partial = xml_stripper << partial if partial.is_a?(String)
                    orig_blk.call(partial, cancel) if partial
                  end
              end

              log =
                start_log(
                  provider_id: provider_id,
                  request_body: request_body,
                  dialect: dialect,
                  prompt: prompt,
                  user: user,
                  feature_name: feature_name,
                  feature_context: feature_context,
                )

              if !@streaming_mode
                return(
                  non_streaming_response(
                    response: response,
                    xml_tool_processor: xml_tool_processor,
                    xml_stripper: xml_stripper,
                    partials_raw: partials_raw,
                    response_raw: response_raw,
                  )
                )
              end

              begin
                cancelled = false
                cancel = -> do
                  cancelled = true
                  http.finish
                end

                break if cancelled

                response.read_body do |chunk|
                  break if cancelled

                  response_raw << chunk

                  decode_chunk(chunk).each do |partial|
                    break if cancelled
                    partials_raw << partial.to_s
                    response_data << partial if partial.is_a?(String)
                    partials = [partial]
                    if xml_tool_processor && partial.is_a?(String)
                      partials = (xml_tool_processor << partial)
                      if xml_tool_processor.should_cancel?
                        cancel.call
                        break
                      end
                    end
                    partials.each { |inner_partial| blk.call(inner_partial, cancel) }
                  end
                end
              rescue IOError, StandardError
                raise if !cancelled
              end
              if xml_stripper
                stripped = xml_stripper.finish
                if stripped.present?
                  response_data << stripped
                  result = []
                  result = (xml_tool_processor << stripped) if xml_tool_processor
                  result.each { |partial| blk.call(partial, cancel) }
                end
              end
              if xml_tool_processor
                xml_tool_processor.finish.each { |partial| blk.call(partial, cancel) }
              end
              decode_chunk_finish.each { |partial| blk.call(partial, cancel) }
              return response_data
            ensure
              if log
                log.raw_response_payload = response_raw
                final_log_update(log)
                log.response_tokens = tokenizer.size(partials_raw) if log.response_tokens.blank?
                log.created_at = start_time
                log.updated_at = Time.now
                log.duration_msecs = (Time.now - start_time) * 1000
                log.save!
                LlmQuota.log_usage(@llm_model, user, log.request_tokens, log.response_tokens)
                if Rails.env.development?
                  puts "#{self.class.name}: request_tokens #{log.request_tokens} response_tokens #{log.response_tokens}"
                end
              end
            end
          end
        end

        def final_log_update(log)
          # for people that need to override
        end

        def default_options
          raise NotImplementedError
        end

        def provider_id
          raise NotImplementedError
        end

        def prompt_size(prompt)
          tokenizer.size(extract_prompt_for_tokenizer(prompt))
        end

        attr_reader :llm_model

        protected

        def tokenizer
          llm_model.tokenizer_class
        end

        # should normalize temperature, max_tokens, stop_words to endpoint specific values
        def normalize_model_params(model_params)
          raise NotImplementedError
        end

        def model_uri
          raise NotImplementedError
        end

        def prepare_payload(_prompt, _model_params)
          raise NotImplementedError
        end

        def prepare_request(_payload)
          raise NotImplementedError
        end

        def decode(_response_raw)
          raise NotImplementedError
        end

        def decode_chunk_finish
          []
        end

        def decode_chunk(_chunk)
          raise NotImplementedError
        end

        def extract_prompt_for_tokenizer(prompt)
          prompt.map { |message| message[:content] || message["content"] || "" }.join("\n")
        end

        def xml_tools_enabled?
          raise NotImplementedError
        end

        def disable_streaming?
          @disable_streaming = !!llm_model.lookup_custom_param("disable_streaming")
        end

        private

        def start_log(
          provider_id:,
          request_body:,
          dialect:,
          prompt:,
          user:,
          feature_name:,
          feature_context:
        )
          AiApiAuditLog.new(
            provider_id: provider_id,
            user_id: user&.id,
            raw_request_payload: request_body,
            request_tokens: prompt_size(prompt),
            topic_id: dialect.prompt.topic_id,
            post_id: dialect.prompt.post_id,
            feature_name: feature_name,
            language_model: llm_model.name,
            feature_context: feature_context.present? ? feature_context.as_json : nil,
          )
        end

        def non_streaming_response(
          response:,
          xml_tool_processor:,
          xml_stripper:,
          partials_raw:,
          response_raw:
        )
          response_raw << response.read_body
          response_data = decode(response_raw)

          response_data.each { |partial| partials_raw << partial.to_s }

          if xml_tool_processor
            response_data.each do |partial|
              processed = (xml_tool_processor << partial)
              processed << xml_tool_processor.finish
              response_data = []
              processed.flatten.compact.each { |inner| response_data << inner }
            end
          end

          if xml_stripper
            response_data.map! do |partial|
              stripped = (xml_stripper << partial) if partial.is_a?(String)
              if stripped.present?
                stripped
              else
                partial
              end
            end
            response_data << xml_stripper.finish
          end

          response_data.reject!(&:blank?)

          # this is to keep stuff backwards compatible
          response_data = response_data.first if response_data.length == 1

          response_data
        end
      end
    end
  end
end
