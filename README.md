# DMS-pilot-testing-kit

[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/Ed-Fi-Exchange-OSS/DMS-pilot-testing-kit/badge)](https://securityscorecards.dev/viewer/?uri=github.com/Ed-Fi-Exchange-OSS/DMS-pilot-testing-kit)

Tools to assist with local pilot testing of the [Ed-Fi API
v8](https://docs.ed-fi.org/reference/ed-fi-api/8/), aka "DMS".

* [Client Integration Pilot Test Proposal](./docs/client-integration-pilot-test-proposal.md)
* [Ed-Fi API v8 Pilot Testing Kit](./ed-fi-api-v8/README.md) -- the Docker Compose environment
  itself: setup, credentials, and troubleshooting for pilot participants.

> [!TIP]
> For more information on the transition from the legacy Ed-Fi ODS/API to Ed-Fi
> API v8+, see the [FAQ](https://docs.ed-fi.org/reference/roadmap/api-faq).

## Pre-requisites

* Docker Desktop (Podman and similar _might_ work but are untested)
* Either Bash or PowerShell 7 (`pwsh`). Both sets of scripts were tested on Windows running
  `amd64` containers.
  * Windows PowerShell 5.1 is not supported.
  * The kit has not been tested on macOS or on arm64 (for example, Apple Silicon).
* Internet access for the first build and start. See the kit's
  [prerequisites](./ed-fi-api-v8/README.md#prerequisites) for details.
* Optional: a client capable of executing request in `.http` files:
  * VS Code [rest-client extension](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) (used / tested by the pilot kit developer)
  * VS Code [httpYac extension](https://marketplace.visualstudio.com/items?itemName=anweber.vscode-httpyac)
  * [Visual Studio 2022+](https://learn.microsoft.com/en-us/aspnet/core/test/http-files?view=aspnetcore-10.0)
  * JetBrains IDEs using the [HTTP Client plugin](https://www.jetbrains.com/help/rider/Http_client_in__product__code_editor.html)

## Contributing

The Ed-Fi Alliance welcomes code contributions from the community. Please read
the [Ed-Fi Contribution Guidelines](https://docs.ed-fi.org/community/sdlc/code-contribution-guidelines/)
for detailed information on how to contribute source code.

> [!TIP]
> Unlike other Ed-Fi Alliance repositories, GitHub Issues are enabled for _ALL_
> users. Please feel free to post requests and problems as Issues in this
> repository. In general do _not_ create [Community
> cases](https://community.ed-fi.org) for problems with this kit.

## Repository Metadata

* [Code of Conduct](./CODE_OF_CONDUCT.md)
* [List of Contributors](./CONTRIBUTORS.md)
* [Copyright and License Notices](./NOTICES.md)
* [License](./LICENSE)

## Legal Information

Copyright (c) 2026 Ed-Fi Alliance, LLC and contributors.

Licensed under the [Apache License, Version 2.0](./LICENSE) (the "License").

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
