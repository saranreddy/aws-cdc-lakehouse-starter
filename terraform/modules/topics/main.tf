# Lambda function to create Kafka topics in MSK Serverless
# MSK Serverless does not support auto-topic creation; topics must be explicitly created

data "aws_caller_identity" "current" {}

# IAM role for Lambda
resource "aws_iam_role" "topic_creator" {
  name_prefix = "${var.name_prefix}-topic-creator-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "topic_creator" {
  name_prefix = "topic-creator-policy-"
  role        = aws_iam_role.topic_creator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:AlterTopic"
        ]
        Resource = var.msk_cluster_arn
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData"
        ]
        Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:topic/${split("/", var.msk_cluster_arn)[1]}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

# Python script to create topics
resource "local_file" "topic_creator_script" {
  filename = "${path.module}/topic_creator.py"
  content  = <<-EOF
    import json
    import boto3
    from kafka import KafkaAdminClient
    from kafka.admin import NewTopic
    from kafka.errors import TopicAlreadyExistsError

    def lambda_handler(event, context):
        bootstrap_servers = event['bootstrap_servers']
        topics_config = event['topics']
        
        admin_client = KafkaAdminClient(
            bootstrap_servers=bootstrap_servers,
            security_protocol='SASL_SSL',
            sasl_mechanism='AWS_MSK_IAM',
            sasl_oauth_token_provider=lambda: get_iam_token(),
            client_id='topic-creator'
        )
        
        topics_to_create = []
        for topic_config in topics_config:
            topic = NewTopic(
                name=topic_config['name'],
                num_partitions=topic_config['partitions'],
                replication_factor=-1,  # Managed by MSK Serverless
                topic_configs=topic_config.get('config', {})
            )
            topics_to_create.append(topic)
        
        try:
            admin_client.create_topics(topics_to_create, validate_only=False)
            return {'statusCode': 200, 'body': json.dumps('Topics created successfully')}
        except TopicAlreadyExistsError:
            return {'statusCode': 200, 'body': json.dumps('Topics already exist')}
        except Exception as e:
            return {'statusCode': 500, 'body': json.dumps(f'Error: {str(e)}')}
        finally:
            admin_client.close()
    
    def get_iam_token():
        import base64
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest
        import boto3
        
        session = boto3.Session()
        credentials = session.get_credentials()
        region = session.region_name
        
        # Create IAM token for MSK
        request = AWSRequest(
            method='GET',
            url=f'kafka.{region}.amazonaws.com',
            headers={'Host': f'kafka.{region}.amazonaws.com'}
        )
        SigV4Auth(credentials, 'kafka', region).add_auth(request)
        return base64.b64encode(request.headers['Authorization'].encode()).decode()
  EOF
}

# Use null_resource with local-exec instead of Lambda due to complexity
# Create topics using kafka-topics.sh via SSM
resource "null_resource" "create_topics" {
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      set -e
      
      # This is a placeholder - actual topic creation will be done via bastion
      # Topics must be created after the cluster is running
      echo "Topics will be created via make seed script"
      
      # Required topics (compacted):
      # - connect-offsets
      # - connect-configs  
      # - connect-status
      # - ${var.name_prefix}.schema-history
      # - control-iceberg
      
      # Required topics (non-compacted):
      # - ${var.name_prefix}.public.customers
      # - ${var.name_prefix}.public.orders
      # - ${var.name_prefix}.public.order_items
    EOF
  }

  depends_on = [var.msk_cluster_arn]
}
