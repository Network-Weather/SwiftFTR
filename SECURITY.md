# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 0.8.x   | :white_check_mark: |
| 0.7.x   | :white_check_mark: |
| < 0.7   | :x:                |

## Reporting a Vulnerability

We take the security of SwiftFTR seriously. If you believe you have found a security vulnerability, please report it to us as described below.

### How to Report

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via one of these methods:

1. **Email**: Send details to the maintainers (see CODEOWNERS file)
2. **GitHub Security Advisory**: [Create a security advisory](https://github.com/Network-Weather/SwiftFTR/security/advisories/new)

### What to Include

Please include the following information to help us understand the nature and scope of the issue:

- Type of issue (e.g., buffer overflow, privilege escalation, data exposure)
- Full paths of source file(s) related to the issue
- Location of affected code (tag/branch/commit or direct URL)
- Any special configuration required to reproduce the issue
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the issue, including how an attacker might exploit it

### Response Timeline

- **Initial Response**: Within 48 hours, we will acknowledge receipt of your report
- **Assessment**: Within 7 days, we will provide an initial assessment and expected resolution timeline
- **Resolution**: Critical vulnerabilities will be addressed as quickly as possible, typically within 30 days

### Disclosure Policy

- We will work with you to understand and resolve the issue promptly
- We will credit you for the discovery in our release notes (unless you prefer to remain anonymous)
- We ask that you give us reasonable time to address the issue before public disclosure

## Security Best Practices for Users

When using SwiftFTR:

1. **Keep Updated**: Always use the latest version to benefit from security patches
2. **Network Permissions**: Be aware that SwiftFTR requires network access for ICMP operations
3. **Input Validation**: When integrating SwiftFTR, validate all user inputs before passing to trace functions
4. **Error Handling**: Properly handle errors to avoid exposing sensitive network topology information

## Security Features

SwiftFTR includes several security-conscious design choices:

- **No sudo required**: Uses SOCK_DGRAM instead of raw sockets on macOS
- **Actor-based concurrency**: Thread-safe by design with Swift 6 strict concurrency
- **Input sanitization**: Validates IP addresses and hostnames before operations
- **Timeout enforcement**: All operations have configurable timeouts to prevent resource exhaustion

## Dependencies

SwiftFTR minimizes external dependencies to reduce attack surface:
- Swift Argument Parser (CLI only)
- Swift DocC Plugin (documentation only)

We regularly review and update dependencies for security patches.

## Contact

For any security-related questions that don't require reporting a vulnerability, please open a discussion in our GitHub repository.