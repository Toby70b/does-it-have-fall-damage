output "cloudfront_distribution_id" {
  description = "Distribution ID, needed for cache invalidations."
  value       = aws_cloudfront_distribution.s3_capsule_image_distribution.id
}

output "cdn_base_url" {
  description = "Base URL for capsule images."
  value       = "https://${local.aliases[0]}"
}