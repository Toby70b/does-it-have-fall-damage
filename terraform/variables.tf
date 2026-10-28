variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "steam_store_base_url" {
  description = "The base URL for the Steam Store API"
  type        = string
  default     = "https://store.steampowered.com"
}
