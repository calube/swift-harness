## Architecture

```mermaid
flowchart LR
  A[OrderQueueReducer] --> B[SubmitOrderEffect]
```

```mermaid
graph TD
  Client --> Queue --> API
```
