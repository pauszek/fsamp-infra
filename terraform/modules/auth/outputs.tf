output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.main.arn
}

output "web_client_id" {
  description = "Web application client ID"
  value       = aws_cognito_user_pool_client.web.id
}

output "resource_server_identifier" {
  description = "Cognito resource server prefix used by access-token scopes"
  value       = aws_cognito_resource_server.api.identifier
}

output "cognito_domain_url" {
  description = "Full Cognito hosted UI domain URL"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}
