# Safety First

Version 2 must be tested on separate TEST objects before production use.

Rules:
- Plan before apply.
- Back up panel objects before changes.
- Never delete objects automatically.
- Do not update existing objects unless they were created by this tool and their UUID is stored in state.
- Do not assign a profile to a node unless explicitly requested.
- Do not replace existing Host node bindings implicitly.
- Stop on any ownership mismatch or failed preflight check.
