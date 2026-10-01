# Formatter bench

Runs BrainDump's formatting prompts against messy test speech and flags the usual failures: answering instead of
rewriting, inventing a closing question, copying words from a prompt example, dropping details.

```sh
bash scripts/formatter-bench/dump_styles.sh > /tmp/styles.json          # the prompts you are shipping
THROTTLE_SLEEP=1.0 python3 scripts/formatter-bench/run.py fast /tmp/styles.json /tmp/out.json --with-dev
python3 scripts/formatter-bench/report.py /tmp/out.json --summary
python3 scripts/formatter-bench/report.py /tmp/out.json --flagged --style email
```

- `inputs_synth.py` holds the synthetic cases (questions, role-play lines, corrections, ticket IDs, developer asks).
  Your own dictation history is also used when it exists (`~/.config/braindump/history.json`, never copied here).
- It runs `llama-server` on port 8190 with the same flags as the app, one request at a time at background priority.
  Run it throttled: a full pass is a few hundred requests and used to make this Mac hot when run in parallel.
- Flags are hints. Read the outputs. The tests in `Tests/OpenWisprTests/FormatterTests.swift` cover the in-app guard.
- Lessons so far: examples in a prompt leak into output when the dictation is vague, so keep them far from your own
  topics; the word "transcript" in a prompt tag made the model treat dictated sentences as instructions.
