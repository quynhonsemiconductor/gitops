# <service>

```
SLO        <availability>% availability, p99 <latency>
SEVERITY   P1 (page) | P2 (business hours)          — §17
OWNER      <name>
```

## Is this actually urgent?

§17: **only rova reaches a phone.** If this is P2 and it is outside business
hours, note it and stop. That is the policy, not an admission of defeat — an SLO
nobody will get out of bed for is not an SLO, and 99.0% is 7.3 hours of budget a
month, which survives a night.

## First three things to look at

```
1  is it the service, or everything?      if every product is alerting, look at the
                                          cluster, the Gateway or Cloudflare before
                                          looking here (§9g)
2  did anything deploy?                   gitops git log — a promotion PR merged in
                                          the last hour is the first suspect
3  what do the traces say?                tail sampling keeps 100% of errors, so the
                                          failing traces ARE there (§9b)
```

## Rollback

```
revert the promotion commit in gitops → ArgoCD syncs → done
```

§13 promises any release from the last 180 days is still in ECR. If the image is
gone, that promise was broken and the retention rule needs looking at — say so
rather than working around it.

## Do not

```
kubectl exec into a production pod    §10b — you cannot, and that is deliberate.
                                      An exec bypasses every audit trail: env vars
                                      carry ESO's secrets, the filesystem is
                                      writable, none of it reaches git. Debugging
                                      production is logs, traces and profiles,
                                      which is what §9 built six signals for
scale it up to make it go away        if it is a capacity problem, KEDA already
                                      scaled it. If KEDA did not, the trigger is
                                      wrong and that is the bug
```

## Known failure modes

<!-- Add them as they happen. A failure mode written down after the first
     occurrence is the cheapest documentation there is; one written speculatively
     is usually wrong. -->

| symptom | cause | fix |
|---|---|---|
| | | |
