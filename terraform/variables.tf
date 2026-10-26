variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "steam_cdn_base_url" {
  description = "The base URL for Steam's capsule image CDN (served per appid)"
  type        = string
  default     = "https://cdn.cloudflare.steamstatic.com/steam/apps"
}
