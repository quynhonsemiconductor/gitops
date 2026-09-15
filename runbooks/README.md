# runbooks/

`charts/qnsc-service/templates/slo.yaml` renders every burn-rate alert with

```
runbook: https://github.com/quynhonsemiconductor/gitops/blob/main/runbooks/<service>.md
```

so an alert that fires at 02:00 links somewhere. **A link to a 404 is worse than no
link** — it costs the responder the time it takes to discover the page is missing,
at the moment that time is most expensive.

One file per service that has an `slo:` block. Copy `_template.md`.

## What a runbook is for

Not "how the service works" — that is the code. A runbook answers one question:
**what do I do right now, at 02:00, half awake.**

§17 sets the context it operates in:

```
rova prod          P1 — someone is awake for this
everything else    P2 — it waits for business hours
```

So most runbooks here end at "note it and stop". That is a correct answer and
should be written down, because the alternative is someone debugging opshub at
02:00 because nothing told them not to.
