terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}


provider "aws" {
  shared_config_files      = ["/Users/markellaskempri/.aws/config"]
  shared_credentials_files = ["/Users/markellaskempri/.aws/credentials"]
  profile                  = "hackathon"
  region = "eu-west-1"
}

locals {
  common_tags = {
    tag-key = "hackathon-2023"
  }
  tablename = "comments"
  transform = <<EOF
{ 
    "TableName": "tablename",
    "Item": {
	    "id": {
            "S": "$context.requestId"
            },
        "comment": {
            "S": $input.json('$')
        }
    }
}
EOF
}

data "aws_region" "current" {}

resource "aws_iam_role" "hack2023-DaxToDynamoDb" {
    name = "hack2023_DaxToDynamoDb"

    assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "dax.amazonaws.com"
        }
      },
    ]
  })
  tags = local.common_tags
  
}

data "aws_iam_policy_document" "dynamo-all-policy-doc" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "dynamodb-all-policy" {
  name        = "dynamodb-all-policy"
  description = "Give DynamoDb access"
  policy      = data.aws_iam_policy_document.dynamo-all-policy-doc.json
  tags = local.common_tags
}

resource "aws_iam_policy_attachment" "dynamo-to-dax" {
    name       = "dynamo-to-dax"
    roles      = ["hack2023_DaxToDynamoDb"]
    policy_arn = aws_iam_policy.dynamodb-all-policy.arn
}

resource "aws_iam_role" "api-to-dynamodb" {
    name = "hack2023_ApiGatewayToDynamoDb"

    assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      },
    ]
  })
  tags = local.common_tags
  
}
resource "aws_iam_policy_attachment" "dynamo-to-apigateway" {
    name       = "dynamo-to-apigateway"
    roles      = ["hack2023_ApiGatewayToDynamoDb"]
    policy_arn = aws_iam_policy.dynamodb-all-policy.arn

}

resource "aws_dax_cluster" "hack_dynamo_cluster" {
  cluster_name       = "hack2023-dax"
  iam_role_arn       = aws_iam_role.hack2023-DaxToDynamoDb.arn
  node_type          = "dax.t2.small"
  replication_factor = 1
  tags = local.common_tags
}

resource "aws_dynamodb_table" "hackathon_2023" {
  name           = local.tablename
  billing_mode   = "PROVISIONED"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "id"
  
  attribute {
    name = "id"
    type = "S"
  }

  tags = local.common_tags
}

resource "aws_api_gateway_rest_api" "api" {
  name = "hack2023-api"
}

resource "aws_api_gateway_resource" "comment-resource" {
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "comment"
  rest_api_id = aws_api_gateway_rest_api.api.id
}

resource "aws_api_gateway_method" "post-comment" {
  authorization = "NONE"
  http_method   = "POST"
  resource_id   = aws_api_gateway_resource.comment-resource.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
}

resource "aws_api_gateway_integration" "dynamodb-integration" {
  http_method = aws_api_gateway_method.post-comment.http_method
  resource_id = aws_api_gateway_resource.comment-resource.id
  rest_api_id = aws_api_gateway_rest_api.api.id
  type        = "AWS"
  integration_http_method = "POST"
  uri = "arn:aws:apigateway:${data.aws_region.current.name}:dynamodb:action/PutItem"
  credentials = aws_iam_role.api-to-dynamodb.arn

  # Transforms the incoming json request to what the post is expecting
    request_templates = {
        "application/json" = replace(local.transform,"tablename",local.tablename)
    }
    passthrough_behavior = "WHEN_NO_TEMPLATES"

}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.comment-resource.id
  http_method = aws_api_gateway_method.post-comment.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "integration_response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.comment-resource.id
  http_method = aws_api_gateway_method.post-comment.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code

  # Returns empty response
  response_templates = {
    "application/json" = ""
  }
}


resource "aws_api_gateway_deployment" "deploy-api" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.comment-resource.id,
      aws_api_gateway_method.post-comment.id,
      aws_api_gateway_integration.dynamodb-integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}


resource "aws_api_gateway_stage" "pre" {
  deployment_id = aws_api_gateway_deployment.deploy-api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "hack2023_pre"
  tags = local.common_tags
}