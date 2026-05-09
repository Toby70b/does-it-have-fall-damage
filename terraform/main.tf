# --- SQS --- #
resource "aws_sqs_queue" "game_capsule_image_lookup" {
  name = "game-capsule_image-lookup"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.game_capsule_image_lookup_dlq.arn
    maxReceiveCount     = 5
  })

  tags = var.tags
}

resource "aws_sqs_queue" "game_capsule_image_lookup_dlq" {
  name = "game-capsule_image-lookup-dlq"
  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "redrive_policy" {
  queue_url = aws_sqs_queue.game_capsule_image_lookup_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.game_capsule_image_lookup.arn]
  })
}

# --- SNS --- #

data "aws_sns_topic" "new_game_item_publisher" {
  name = "new-game-items"
}

resource "aws_sns_topic_subscription" "user_updates_sqs_target" {
  topic_arn = data.aws_sns_topic.new_game_item_publisher.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.game_capsule_image_lookup.arn
  raw_message_delivery = true
}

resource "aws_sqs_queue_policy" "game_capsule_image_lookup" {
  queue_url = aws_sqs_queue.game_capsule_image_lookup.id
  policy    = data.aws_iam_policy_document.sqs_queue_policy.json
}

data "aws_iam_policy_document" "sqs_queue_policy" {
  policy_id = "arn:aws:sqs:us-west-2:123456789012:user_updates_queue/SQSDefaultPolicy"

  statement {
    sid    = "user_updates_sqs_target"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions = [
      "SQS:SendMessage",
    ]

    resources = [
      aws_sqs_queue.game_capsule_image_lookup.arn,
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"

      values = [
        data.aws_sns_topic.new_game_item_publisher.arn
      ]
    }
  }
}

# --- S3 === #
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "steam_game_capsule_image" {
  bucket        = "steam-game-capsule_image-${random_id.bucket_suffix.hex}"
  tags          = var.tags
}

# --- Lambda --- #
data "archive_file" "game_capsule_image_lookup" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/capsule_image_lookup/src"
  output_path = "${path.module}/files/capsule_image_lookup.zip"
}

resource "aws_iam_role" "game_capsule_image_lookup_lambda_role" {
  name = "game-capsule_image-lookup-lambda-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "game_capsule_image_lookup_lambda_policy" {
  name = "ddb-export-lambda-policy"
  role = aws_iam_role.game_capsule_image_lookup_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.steam_game_capsule_image.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.game_capsule_image_lookup.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "game_capsule_image_lookup" {
  filename         = data.archive_file.game_capsule_image_lookup.output_path
  source_code_hash = data.archive_file.game_capsule_image_lookup.output_base64sha256

  function_name    = "game-capsule-image-lookup"
  role             = aws_iam_role.game_capsule_image_lookup_lambda_role.arn
  handler          = "capsule_image_lookup.handler.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 128
  tags             = var.tags

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.steam_game_capsule_image.bucket
      STEAM_STORE_BASE_URL = "https://store.steampowered.com/api/appdetails"
    }
  }
}

resource "aws_lambda_event_source_mapping" "new_game_item_stream" {
  event_source_arn  = aws_sqs_queue.game_capsule_image_lookup.arn
  function_name     = aws_lambda_function.game_capsule_image_lookup.arn

  # Batch settings -  need to consider initial setup scenario
  batch_size                         = 10
  maximum_batching_window_in_seconds = 10
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 5
  }

  tags = var.tags
}