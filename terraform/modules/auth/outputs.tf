output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.main.arn
}

output "user_pool_endpoint" {
  description = "Cognito User Pool endpoint"
  value       = aws_cognito_user_pool.main.endpoint
}

output "user_pool_domain" {
  description = "Cognito User Pool domain"
  value       = aws_cognito_user_pool_domain.main.domain
}

output "web_client_id" {
  description = "Web application client ID"
  value       = aws_cognito_user_pool_client.web.id
}

output "resource_server_identifier" {
  description = "Cognito resource server prefix used by access-token scopes"
  value       = aws_cognito_resource_server.api.identifier
}

output "service_client_id" {
  description = "Service client ID (for M2M auth)"
  value       = aws_cognito_user_pool_client.service.id
}

output "service_client_secret" {
  description = "Service client secret (for M2M auth)"
  value       = aws_cognito_user_pool_client.service.client_secret
  sensitive   = true
}

output "cognito_domain_url" {
  description = "Full Cognito hosted UI domain URL"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}
