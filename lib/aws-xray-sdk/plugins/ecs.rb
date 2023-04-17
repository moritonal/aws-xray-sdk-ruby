require "socket"
require "aws-xray-sdk/logger"

module XRay
  module Plugins
    module ECS
      include Logging

      ORIGIN = "AWS::ECS::Container".freeze

      METADATA_BASE_URL_ENVIRONMENT_VARIABLE =
        "ECS_CONTAINER_METADATA_URI_V4".freeze

      def self.aws
        @@aws ||=
          begin
            metadata_uri =
              ENV.fetch(METADATA_BASE_URL_ENVIRONMENT_VARIABLE, nil)

            if metadata_uri.nil?
              get_metadata_without_endpoint
            else
              get_metadata_with_endpoint(URI(metadata_uri))
            end
          rescue StandardError => e
            @@aws = {}
            Logging.logger.warn %(cannot get the ecs container hostname due to: #{e.message}.)
          end
      end

      private

      def self.get_metadata_without_endpoint
        { ecs: { container: Socket.gethostname } }
      end

      def self.get_metadata_with_endpoint(metadata_uri)

        if metadata_uri.nil?
          Logging.logger.warn("metadata_uri is not set")
          return {}
        else
          Logging.logger.debug("metadata_uri is #{metadata_uri}")
        end

        req = Net::HTTP::Get.new(metadata_uri)

        begin
          metadata_json = do_request(req)
          return parse_metadata(metadata_json)
        rescue StandardError => e
          Logging.logger.warn %(cannot get the ec2 instance metadata due to: #{e.message}.)
          {}
        end
      end

      def self.parse_metadata(json_str)
        data = JSON(json_str)

        {}.merge(
          **parse_ecs_metadata(data),
          **parse_cloudwatch_logs_metadata(data)
        )
      end

      def self.parse_cloudwatch_logs_metadata(data)
        logs = nil

        log_options = data["LogOptions"]

        if log_options.nil?
          Logging.logger.debug("log_options is not set")
          return {}
        end

        log_group = log_options["awslogs-group"]

        if log_options.nil?
          Logging.logger.debug("log_group is not set")
          return {}
        end

        labels = data["Labels"]

        cluster_arn = labels["com.amazonaws.ecs.cluster"]

        if !Aws::ARNParser.arn?(cluster_arn)
          Logging.logger.debug("cluster_arn is not set")
          return {
            cloudwatch_logs:
            {
              log_group: log_group
            }
          }
        end

        cluster_arn = Aws::ARNParser.parse(cluster_arn)

        Logging.logger.debug("cluster_arn is set to #{cluster_arn}")

        log_arn = "arn:aws:logs:#{cluster_arn.region}:#{cluster_arn.account_id}:log-group:#{log_group}:*"

        Logging.logger.debug("log arn calculated to be #{log_arn}")

        return {
          cloudwatch_logs:
          {
            arn: log_arn,
            log_group: log_group
          }
        }
      end

      def self.parse_ecs_metadata(data)
        container = nil

        data["Networks"].each do |network|
          case network["NetworkMode"]
          when "awsvpc"
            container = network["PrivateDNSName"]
          else
            Logging.logger.debug(
              "NetworkMode #{network["NetworkMode"]} is not supported"
            )
          end
        end

        container_id = data["DockerId"]
        container_arn = data["ContainerARN"]

        if container_id.nil? || container.nil? || container_arn.nil?
          Logging.logger.warn(
            "cannot get the container metadata due to: missing container_id, container or container_arn. Falling back to hostname."
          )
          return get_metadata_without_endpoint
        end

        return(
          {
            ecs: {
              container: container,
              container_id: container_id,
              container_arn: container_arn
            }
          }
        )
      end

      def self.do_request(request)
        begin
          response =
            Net::HTTP.start(request.uri.hostname, read_timeout: 1) do |http|
              http.request(request)
            end

          if response.code == "200"
            return response.body
          else
            raise(
              StandardError.new(
                "Unsuccessful response::" + response.code + "::" +
                  response.message
              )
            )
          end
        rescue StandardError => e
          # Two attempts in total to complete the request successfully
          @retries ||= 0
          if @retries < 1
            @retries += 1
            retry
          else
            Logging.logger.warn %(Failed to complete request due to: #{e.message}.)
            raise e
          end
        end
      end
    end
  end
end
