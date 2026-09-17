# Proposed Pilot Test of Client Integrations with Ed-Fi API v8

## Purpose

The purpose of this pilot is to validate the operational readiness,
conformance, and performance of the Ed-Fi API v8 platform by exercising it with
production-grade third-party client integrations. While the platform has
undergone extensive internal testing, additional confidence can be gained by
executing a controlled pilot using independent implementations built by the
organizations that will depend on the platform in production.

> [!TIP]
> See [Client Integration Pilot PRD](./client-integration-pilot-PRD.md) for the
> detailed required requirements that will drive creation of the pilot testing
> kit.

## Client Integrations in Scope

A *client integration* is any system that reads from or writes to an Ed-Fi API.
The pilot seeks participants across three representative shapes:

- **Student Information System (SIS) integrations.** Write-oriented. Submit
  core enrollment, demographic, staff, schedule, and calendar data, typically
  as a large initial load followed by incremental updates.
- **Assessment provider integrations.** Write-oriented, with a narrower
  resource footprint. Submit assessment metadata and student assessment
  results, and depend on resolving references to student and education
  organization records created by another system.
- **Downstream data warehouse and analytics loads.** Read-oriented. Extract
  data out of the API, through full paged reads and incremental change-query
  reads, for loading into a warehouse or reporting platform.

Participation from all three shapes matters because they exercise different
parts of the platform. The write-oriented integrations stress validation,
reference resolution, and write throughput; the read-oriented integrations
stress paging, change queries, and query performance.

## Scope

Participating organizations will be provided with:

- A preconfigured deployment package based on Docker Compose, configured with
  Ed-Fi Data Standard 5.2.
- A choice of starting data set: a "minimal template" containing descriptors
  only, or a "populated template" that adds the Ed-Fi synthetic sample data.
  Write-oriented integrations will normally use the minimal template;
  downstream data warehouse integrations need the populated template, because
  an empty database gives them nothing to extract.
- Associated configuration and setup scripts.
- Documentation sufficient to enable installation and initial operation within
  a short period of time, with a goal of requiring less than one hour of setup
  effort.

The pilot will ask participants to:

- Deploy the provided environment in a non-production testing environment.
- Exercise the Ed-Fi API v8 platform with their own client: submitting
  representative data, extracting data, or both, as fits their integration.
- Report any installation, configuration, interoperability, or data-processing
  issues encountered during testing.

## Evaluation Criteria

Where feasible, testing results will be collected through automated scripts and
logs. Metrics of interest include:

- Error counts generated during processing.
- Successfully processed or landed record counts, for write-oriented
  integrations.
- Records retrieved, requests issued, and extract completeness, for
  read-oriented integrations.
- End-to-end processing duration, measured from the first inbound request to
  completion of the run.

Results will be segmented by integration shape and by starting template, since
throughput against a populated database is not comparable to throughput against
an empty one, and records retrieved is not comparable to records landed.

## Comparative Testing

As an optional activity, participants may also execute the same exercise
against a current Ed-Fi ODS/API implementation provided in the same package.
Comparative results would help assess behavioral consistency, performance
characteristics, and readiness for migration to the new platform.

## Desired Outcomes

The pilot is intended to:

- Demonstrate successful interoperability between third-party client
  integrations and the Ed-Fi API v8 platform, across both write and read
  access patterns.
- Validate deployment and onboarding processes for external implementers.
- Identify integration, usability, or operational issues prior to broader
  market adoption.
- Generate real-world evidence of product readiness that can inform future
  release planning and community guidance.

## Participation Expectations

Participating organizations are asked to contribute feedback on installation
experience, configuration requirements, data processing outcomes, and overall
usability. This feedback will be used to improve documentation, deployment
automation, and product quality prior to general availability.
