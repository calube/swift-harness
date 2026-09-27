---
type: llm
focus: last_message
---
The agent ran /swift-harness:design headless, where it can't ask through a tool. Its final message
must end the turn with the frame questions of 1 prompt in this shape.

PASS only if all of these hold:
1. The questions are numbered, and there are at most 4 of them.
2. Each question has its options as a lettered list (a, b, c or A, B, C).
3. In each question, the first option is labelled "(Recommended)" and has a short description.
4. The questions are frame questions: area, touched modules, new modules and their kinds, or new
   dependencies. A constraints question isn't among them; it waits for the next turn.
5. A last line says the answers come back through
   `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 claude -p --resume <session id>`.
6. The message doesn't claim a plan, a branch or a file was created.
FAIL if any is missing. Say which step failed.
