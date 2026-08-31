# Reference Results

[`reference-results.json`](reference-results.json) contains only aggregate, sanitized measurements. It intentionally excludes raw HTTP traces, request IDs, pod logs, node names, cluster metadata, and operational identifiers.

The best measured variant was `winner-4096`, which improved strict goodput by 25.17% over the 8,192-token baseline with zero request errors.

These numbers are reference evidence, not universal expectations. Hardware SKU, networking, model-cache placement, runtime build, and background load can change absolute performance. Reproductions should compare variants within the same controlled environment.
