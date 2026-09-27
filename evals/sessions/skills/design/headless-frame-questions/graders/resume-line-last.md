---
type: regex
target: last_message
pattern: 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 claude -p --resume[^\n]*\s*$'
---
The resume line is the message's last line, as the headless shape in
`references/frame-research-verify.md` says: nothing follows the instructions for answering.
