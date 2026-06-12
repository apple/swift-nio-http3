# Contributing guide

Welcome to the [SwiftNIO](https://github.com/apple/swift-nio) community! Contributions to the SwiftNIO HTTP/3 project are welcomed and encouraged. This project aligns with the Swift community [contributing guidelines](https://swift.org/contributing) which is a great first read.

We welcome developers from all backgrounds and experience levels. A diverse and friendly community has more great ideas, more unique perspectives, and produces better software.

## How you can help

- Reporting bugs with clear, reproducible steps as GitHub Issues
- Improving documentation to make the project more accessible
- Adding or enhancing tests to improve reliability and coverage
- Proposing and implementing enhancements
- Participating in the [Networking](https://forums.swift.org/c/development/networking/129) or [Server](https://forums.swift.org/c/server/43) topics on the Swift Forums

## Setting up your environment

See the [README](README.md) for prerequisites and build instructions.

## Issues and bugs

Use GitHub Issues to report bugs, request features, or provide feedback. Please submit an Issue before doing time-consuming or complex work to get acknowledgement from the maintainers.

Specify the following:

- SwiftNIO HTTP/3 version
- Contextual information (e.g. what you were trying to achieve with swift-nio-http3)
- Simplest possible steps to reproduce
- The more complex the steps are, the lower the priority will be.
- A pull request with failing test case is preferred, but it's just fine to paste the test case into the issue description.
- Anything that might be relevant in your opinion, such as:
  - Swift version or the output of swift --version
  - OS version and the output of uname -a
  - Network configuration

### Example 
```
SwiftNIO HTTP/3 version: 0.1.0

Context:
While testing my application that uses swift-nio-http3, I noticed that ...

Steps to reproduce:
1. ...
2. ...
3. ...
4. ...

$ swift --version
Swift version 6.3.2 (swift-6.3.2-RELEASE)
Target: aarch64-unknown-linux-gnu

$ uname -a
Linux 924ed8c5-d086-47b8-9898-7195fd50710a 6.18.15-cz-325d33a88139 #1 SMP Mon Apr 20 22:39:49 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
```

## Submitting pull requests

A good SwiftNIO HTTP/3 pull request is:

- Concise, and contains as few changes as needed to achieve the end result.
- Tested, ensuring that any tests provided failed before the patch and pass after it.
- Documented, adding API documentation as needed to cover new functions and properties.
- Accompanied by a great commit message
  
### Tests and running CI

Thorough testing is required for all contributions and all checks must pass before merging.

Local Testing: Before submission, ensure all changes pass local tests:
```
swift test
```
Automated Tests: New features and bug fixes require corresponding automated tests (unit, integration, end-to-end) that validate the intended behavior and prevent regressions. You are responsible for verifying the correctness and coverage of all tests.

## Code of Conduct

We've adopted the [Apple Open Source Code of Conduct](https://github.com/apple/.github/blob/main/CODE_OF_CONDUCT.md). All community members are expected to adhere to these guidelines.

## Legal

By submitting a pull request, you represent that you have the right to license your contribution to Apple and the community, and agree by submitting the patch that your contributions are licensed under the Apache 2.0 license (see LICENSE.txt).
