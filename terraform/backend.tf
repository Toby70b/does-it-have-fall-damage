terraform {
  backend "s3" {
    bucket       = "terraform-state-does-it-have-fall-damage-8318927"
    key          = "terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
