# Shape-only ToolAgent Trace

`toolagent-shape-trace.jsonl.gz` contains 5,775 synthetic trace rows with only:

- relative request timestamp
- input token length
- output token length
- integer prefix-block identifiers used to reproduce sharing structure

It contains no prompts, generated text, user names, request IDs, network addresses, credentials, or cluster identifiers.

Integrity:

- Compressed SHA-256: `f081d6352e0f02862fb242146372b47ececc6f661e92935c528dcceefbdfcb20`
- Decompressed SHA-256: `ce4308b6f19d10fdaf79f10179b04dcb652f4fcc4cf26e5c1388f6e575fc37b2`
- Timestamp range: 0–1,196,248 ms
- Effective offered rate: 4.826758331048411 requests/s
