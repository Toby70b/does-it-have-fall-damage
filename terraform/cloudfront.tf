locals {
  s3_origin_id     = "capsule-images-s3"
  top_level_domain = "tobypeel.com"
  aliases          = ["cdn.tobypeel.com"]
}

resource "aws_cloudfront_origin_access_control" "images" {
  name                              = "images-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "images" {
  name = "Managed-CachingOptimizedForUncompressedObjects"
}

resource "aws_cloudfront_distribution" "s3_capsule_image_distribution" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = local.aliases
  price_class     = "PriceClass_100"
  # Keeps a request for / from reaching S3 as a ListObjects call.
  # The object intentionally does not exist, so the bare domain 404s.
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.steam_game_capsule_image.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.images.id
    origin_id                = local.s3_origin_id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = false

    cache_policy_id            = data.aws_cloudfront_cache_policy.images.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.capsule_image_cache_headers.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = var.tags
}

resource "aws_cloudfront_response_headers_policy" "capsule_image_cache_headers" {
  name = "image_cache_policy"

  custom_headers_config {
    items {
      header   = "Cache-Control"
      value    = "public, max-age=86400, s-maxage=31536000"
      override = true
    }
  }
}

data "aws_route53_zone" "capsule_domain" {
  name         = local.top_level_domain
  private_zone = false
}

resource "aws_route53_record" "cloudfront_a_record" {
  for_each = toset(local.aliases)
  zone_id  = data.aws_route53_zone.capsule_domain.zone_id
  name     = each.value
  type     = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_capsule_image_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_capsule_image_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cloudfront_aaaa_record" {
  for_each = toset(local.aliases)
  zone_id  = data.aws_route53_zone.capsule_domain.zone_id
  name     = each.value
  type     = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.s3_capsule_image_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_capsule_image_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_acm_certificate" "cert" {
  region                    = "us-east-1"
  domain_name               = "*.${local.top_level_domain}"
  subject_alternative_names = [local.top_level_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "route53_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.capsule_domain.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cert_validation" {
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.route53_validation : r.fqdn]
}