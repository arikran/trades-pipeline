# Binance trades pipeline

Binance publishes every trade on a public WebSocket. Two producers read it and write each trade to a Kafka topic on Amazon MSK. A consumer reads the topic and writes the trades to PostgreSQL on RDS. The producers and the consumer run on EKS, and all of it is built with Terraform, in `eu-north-1`.

It is running now, in account 092988563851, deployed from commit `86ec2b6`. Later commits change only this README and code comments. You do not need to deploy it to look at it: `make health` needs only AWS credentials, and the queries under "Re-running the proofs" need cluster access. Quick check: `make health` should print `OK`.

```
Binance WebSocket ──> producer x2 ──> MSK topic "trades" ──> consumer (KEDA, 2-5) ──> RDS PostgreSQL
                        (EKS)          (6 partitions, RF 3)        (EKS)               table "trades"
```

**Contents:** [What you need](#what-you-need) · [Cluster access](#cluster-access) · [Deploy](#deploy) · [Destroy](#destroy) · [Health](#health) · [Re-running the proofs](#re-running-the-proofs) · [Freshness target](#freshness-target) · [Evidence](#evidence) · [Design decisions](#design-decisions) · [Assumptions and shortcuts](#assumptions-and-shortcuts) · [Repo layout](#repo-layout)

## What you need

- Terraform >= 1.11 (I used 1.14.3), AWS CLI v2, kubectl, Docker that can build `linux/amd64`, GNU make, bash, git.
- Credentials for account 092988563851 with admin-level permissions, including `kafka-cluster:*` (Terraform manages the MSK topic through the Kafka API). `make preflight` checks that `aws`, `terraform`, `kubectl` and `docker` are installed and that the credentials are for this account. It does not check that the Docker daemon is running, which the image build needs after the infrastructure apply.

```
export AWS_PROFILE=<your profile for 092988563851>
export AWS_REGION=eu-north-1
export TF_VAR_alert_email=<address for the alarm emails>        # optional
export TF_VAR_evaluator_principal_arn=<an IAM user or role ARN> # optional, cluster access for a second principal
```

`TF_VAR_alert_email` is optional, but once it is set it has to be set on every apply: if it is empty, Terraform removes the email subscription. AWS first sends a confirmation email to that address, and no alarm email arrives until the link in it is clicked.

## Cluster access

The cluster uses EKS access entries. The principal that runs the apply gets cluster-admin, and `TF_VAR_evaluator_principal_arn` gives it to one more principal. Today only my IAM user has an entry. For `kubectl`, `make query` and the tested destroy path, add one for your principal:

```
aws eks create-access-entry --region eu-north-1 --cluster-name arik-rainish-eks --principal-arn <your ARN>
aws eks associate-access-policy --region eu-north-1 --cluster-name arik-rainish-eks --principal-arn <your ARN> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
make kubeconfig
```

Use an IAM user ARN or a role ARN, not the assumed-role session ARN that `aws sts get-caller-identity` prints when you use SSO or a role. SSO roles have a path in their ARN, so take it from `aws iam get-role --role-name <name> --query Role.Arn`.

## Deploy

```
make deploy
```

It runs, in order:

1. `preflight`: tools and account.
2. `terraform -chdir=infra apply`: VPC, EKS, MSK, RDS, ECR, IAM roles, alarms.
3. `scripts/build-push.sh`: builds both images and pushes them to ECR. The tag is the git commit SHA. A tag that already exists is skipped.
4. `terraform -chdir=apps apply`: KEDA and the pipeline Helm chart.
5. `make kubeconfig`: adds the context `trades-pipeline` to your kubeconfig and switches to it.
6. `kubectl rollout status` for the producers. Helm's wait returns once the new pods are Ready; this also waits for the 30 s `minReadySeconds` and for the last old producer to stop.

A deploy from nothing took about 40 minutes. Most of it is MSK (29 minutes to create). EKS took 8 minutes and RDS 5. On the running stack, `make deploy` from a newer commit builds images with the new tag and replaces the pods one at a time.

If the very first install of the Helm release fails half way (for example the 600 s wait times out), the release exists in the cluster but not in the Terraform state, and the next apply refuses to install it again; `terraform -chdir=apps import helm_release.pipeline pipeline/pipeline` fixes that.

## Destroy

```
make destroy
make verify-clean
```

Add your access entry first (Cluster access, above). `make destroy` then removes the in-cluster layer through the Helm provider, and then the infrastructure; that is the path I tested. Without an entry, the pinned Helm provider (3.3.0) cannot read the releases and drops them from its state, so it reports nothing to destroy in `apps`; if the provider errors instead, `make destroy` says so and goes on. Either way the infrastructure destroy then deletes the cluster, and the chart owns no AWS resources (no Service of type LoadBalancer, no volumes), so that removes everything that ran in it. Any release still left in the `apps` state is dropped at the end.

`make verify-clean` lists anything left in AWS. Every section should be empty. The sections `tagged`, `eks-tagged` and `k8s-owned` use the tagging API, which can list resources for up to an hour after they are deleted. The other sections query each service directly. A few of them (`eip-free`, `eni-free`, `gd-endpoints`, `gd-sgs`, `ebs-free`, `elbv2`, `elb-classic`, `secrets`) look at the whole account, so they can show resources that are not from this stack. Three things stay by design: the Terraform state objects in the provided S3 bucket, the CloudWatch metrics (they cannot be deleted and expire on their own), and the kubeconfig context `trades-pipeline` on your machine.

I tested the full cycle with cluster access on 20.11: `make destroy` removed 2 resources in `apps` and 81 in `infra` (one alarm fewer than today) in about 15 minutes, `verify-clean` found nothing in the direct checks, and `make deploy` brought everything back. The destroy target got its fallback and the state cleanup on 22.11, after that run. I have one principal in this account, so the path without cluster access is not tested against AWS; I tested the order of the steps with stubbed `terraform` and `aws` commands.

## Health

```
make health
```

It prints the state of the composite alarm `arik-rainish-health`: `OK` or `ALARM`. In the first minutes after the alarms are created it can print `INSUFFICIENT_DATA`, and a deploy from nothing then shows `ALARM` for a few minutes (see below). Without make:

```
aws cloudwatch describe-alarms --alarm-names arik-rainish-health --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[0].StateValue' --region eu-north-1 --output text
```

The composite is `ALARM` when any of these alarms is:

- `arik-rainish-freshness`: the consumer publishes a `FreshnessSeconds` metric, the worst delay in each 10 s window between a trade's time at Binance and the moment it is written to the DB. The alarm fires when the 1-minute maximum is above 5 s for 3 minutes in a row. Missing data counts as breaching, so a dead consumer fires it too.
- `arik-rainish-lag`: MSK's `EstimatedMaxTimeLag` for the consumer group is above 60 s for 3 minutes.
- `arik-rainish-backlog`: MSK's `MaxOffsetLag`, the messages waiting in the busiest partition, is above 10,000 for 3 minutes. Apart from proofs 4 and 4b, its hourly peak has stayed under 600 since the redeploy on 20.11.

Only the composite sends email (SNS): one ALARM email per incident, and one OK email when it recovers. When the consumers stopped completely, the email came 7 minutes later (proof 4b, below): each alarm needs 3 one-minute periods, and the metrics take a few minutes to reach CloudWatch.

I started with the first two. Proof 4 (below) showed that with no consumer running, `EstimatedMaxTimeLag` stays at 0: it is AWS's estimate of the time to drain the backlog, and my reading is that with nobody reading there is no rate to estimate from. In the same minutes `MaxOffsetLag` grew by about 10,000 a minute, and only the freshness alarm fired. So I added the backlog alarm, and proof 4b shows it firing.

A deploy from nothing raises one ALARM, because the alarms exist before the consumers write their first metric and missing data is breaching. On 20.11 the composite went from `INSUFFICIENT_DATA` to `ALARM` at 18:21 UTC and back to `OK` at 18:27.

## Re-running the proofs

```
make query SQL=scripts/duplicates.sql   # any (symbol, trade_id) stored twice; expect 0 rows (reads the whole table)
make query SQL=scripts/gaps.sql         # missing trade ids per symbol, last 10 minutes; expect 0
make query SQL=scripts/freshness.sql    # age of the newest trade, average ingest delay over the last minute (reads the whole table)
```

The two whole-table queries load the small RDS instance; run them one at a time.

`make query` pipes the file into `app/consumer/query.py` inside the consumer pod (`kubectl exec`). It connects as `trades_app`, the consumer's own DB user, in a read-only transaction, so no one handles a password and the RDS stays private. The file runs as one prepared statement, so it cannot end the read-only transaction (for example with `COMMIT;`) and then write. It needs cluster access (Cluster access, above), so kubectl points at this cluster.

## Freshness target

5 seconds from Binance to the table. In normal running the metric averages about 1.2 s (it is the worst trade in each 10 s window; per trade the delay is about 0.6 s), and the worst value in an hour is usually under 3 s (proof 6); on 22.11, outside my tests, it reached 4.2 s, still under the 5 s target. The alarm needs 3 minutes in a row above the target, so a shorter breach shows in the metric but sends no email, like the 48 s spike during proof 3b, visible in proof 6 (most likely librdkafka's default 45 s session timeout, before the killed consumer's partitions moved to another one).

The assignment notes that volume varies by an order of magnitude. KEDA scales the consumers between 2 and 5 on consumer lag. In proof 4 they read a backlog of 121,312 messages on the busiest partition within about a minute, while new messages arrived at about 10,000 a minute. More consumers do not help one partition: BTC is alone on its partition, so its headroom is what one consumer can write, and proof 4 shows that is about ten times today's rate, so a tenfold BTC peak would use all of it: BTC freshness would then grow, and adding consumers would not help.

## Evidence

All of these ran on EKS, on 21.11 and 22.11. Times in the prose are UTC; the AWS CLI printed its timestamps in my local time (`+02:00`). `make query` is explained under "Re-running the proofs". `[...]` marks lines I cut from the output. Pod names differ between proofs because I deployed new versions on 22.11. Proofs 1 to 6 ran on the versions of 21.11 and of 22.11 before 19:50 UTC; proof 7 shows the final version, and proof 8 the whole table after everything.

| # | What it shows | Result |
|---|---|---|
| 1 | Trades flow | all 9 symbols grew; 2,966 BTC trades in 72 s |
| 2 | No duplicates, no gaps | 0 duplicates, 0 missing; half of the messages dropped as duplicates by the primary key |
| 3 / 3b | Consumer SIGTERM / kill -9 | clean exit; restart and KEDA 2 to 5; 0 missing, 0 duplicates |
| 4 / 4b | Consumers stopped | freshness, then backlog alarm and email; recovery in 1-2 minutes; lag alarm stays OK |
| 5 / 5b | Producer dies / Binance drops | the second producer covers; reconnect and backfill of 3,936 trades, RESTARTS 0 |
| 6 | 24 h freshness | worst value under 3 s in 22 of 24 hours; the 2 exceptions are my tests |
| 7 | Final version `86ec2b6` | rollout done, 0 duplicates, 0 missing, health OK |
| 8 | Whole table | 23,642,603 trades, 0 missing |

### 1. Trades flow into the table

```
$ Q="SELECT symbol, count(*) FROM trades GROUP BY 1 ORDER BY 1"
$ { date -u; echo "$Q" | kubectl -n pipeline exec -i deploy/consumer -- python query.py; sleep 60; date -u; echo "$Q" | kubectl -n pipeline exec -i deploy/consumer -- python query.py; }
Sat Nov 21 12:28:33 UTC 2026
symbol   | count
---------+--------
ADAUSDT  | 111628
AVAXUSDT | 170588
BNBUSDT  | 908197
BTCUSDT  | 5214819
DOGEUSDT | 468148
ETHUSDT  | 4006301
LINKUSDT | 280540
SOLUSDT  | 1019867
XRPUSDT  | 532934
(9 rows)
Sat Nov 21 12:29:45 UTC 2026
symbol   | count
---------+--------
ADAUSDT  | 111713
AVAXUSDT | 170629
BNBUSDT  | 908476
BTCUSDT  | 5217785
DOGEUSDT | 468303
ETHUSDT  | 4008174
LINKUSDT | 280617
SOLUSDT  | 1020304
XRPUSDT  | 533144
(9 rows)
```

All 9 symbols grew. For example, 2,966 new BTC trades in 72 seconds.

### 2. No duplicates and no gaps

```
$ make query SQL=scripts/duplicates.sql
symbol | trade_id | count
-------+----------+------
(0 rows)
$ make query SQL=scripts/gaps.sql
symbol   | rows  | missing
---------+-------+--------
ADAUSDT  | 1708  | 0
AVAXUSDT | 1988  | 0
BNBUSDT  | 7322  | 0
BTCUSDT  | 52823 | 0
DOGEUSDT | 4481  | 0
ETHUSDT  | 30893 | 0
LINKUSDT | 2979  | 0
SOLUSDT  | 10789 | 0
XRPUSDT  | 5034  | 0
(9 rows)
$ kubectl logs -n pipeline -l app.kubernetes.io/name=consumer --since=10m --tail=-1 | awk '/duplicates_skipped/{gsub(",","");b+=$5;i+=$7;d+=$9} END{print "processed",b,"inserted",i,"dropped_dups",d}'
processed 238415 inserted 119207 dropped_dups 119208
```

Both producers send every trade, so half of the messages are duplicates. The primary key `(symbol, trade_id)` with `ON CONFLICT DO NOTHING` drops them. With that primary key `duplicates.sql` cannot return a row; it is there as a check, and the consumer's own counters (the last command) are the evidence.

### 3. Consumer restart

```
$ kubectl delete -n pipeline $(kubectl get pod -n pipeline -l app.kubernetes.io/name=consumer -o name | head -1)
pod "consumer-668686c5b8-csncd" deleted from pipeline namespace
$ sleep 60; kubectl get pods -n pipeline -l app.kubernetes.io/name=consumer
NAME                        READY   STATUS    RESTARTS   AGE
consumer-668686c5b8-l97m5   1/1     Running   0          65s
consumer-668686c5b8-rdwzt   1/1     Running   0          18h
```

On SIGTERM the consumer finishes its batch, commits to the DB and then to Kafka, and exits. This is the log of another consumer pod, followed with `kubectl logs -f` while I deleted it:

```
2026-11-21 15:40:39,180 INFO batch 16, inserted 8, duplicates_skipped 8
2026-11-21 15:40:39,180 INFO SIGTERM: last batch committed, closing
2026-11-21 15:40:39,180 INFO revoked partitions [0, 3, 5]
2026-11-21 15:40:39,189 INFO clean exit
```

### 3b. Consumer crash (kill -9) and a scaling event

```
$ kubectl debug node/ip-10-0-34-105.eu-north-1.compute.internal --image=busybox:1.36 -- chroot /host pkill -9 -f consumer.py
[...]
$ sleep 60; kubectl get pods -n pipeline
NAME                        READY   STATUS      RESTARTS       AGE
consumer-668686c5b8-42m9d   1/1     Running     0              65s
consumer-668686c5b8-d6ld4   1/1     Running     0              80s
consumer-668686c5b8-l97m5   1/1     Running     1 (103s ago)   19m
consumer-668686c5b8-ldckd   1/1     Running     0              80s
consumer-668686c5b8-rdwzt   1/1     Running     0              18h
db-init-djrs2               0/1     Completed   0              18h
producer-65c99b6d5b-8fznq   1/1     Running     0              18h
producer-65c99b6d5b-vsh9j   1/1     Running     0              18h
$ make query SQL=scripts/gaps.sql
symbol   | rows  | missing
---------+-------+--------
ADAUSDT  | 416   | 0
AVAXUSDT | 659   | 0
BNBUSDT  | 4168  | 0
BTCUSDT  | 29331 | 0
DOGEUSDT | 1734  | 0
ETHUSDT  | 17487 | 0
LINKUSDT | 970   | 0
SOLUSDT  | 4155  | 0
XRPUSDT  | 2262  | 0
(9 rows)
$ make query SQL=scripts/duplicates.sql
symbol | trade_id | count
-------+----------+------
(0 rows)
```

`l97m5` restarted once (the kill), and KEDA scaled the consumer from 2 to 5 while the lag was high.

A batch the killed process wrote but did not commit to Kafka is read again by the next owner of those partitions, and the primary key skips it: `duplicates.sql` above shows 0 rows.

### 4. Consumers stopped: the alarm fires, then recovery

```
$ kubectl annotate scaledobject consumer -n pipeline autoscaling.keda.sh/paused-replicas="0" --overwrite
scaledobject.keda.sh/consumer annotated
$ kubectl get hpa -n pipeline
No resources found in pipeline namespace.
$ aws cloudwatch describe-alarms --alarm-name-prefix arik-rainish --alarm-types MetricAlarm CompositeAlarm --query '[MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp], CompositeAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]]' --output text
arik-rainish-freshness  ALARM   2026-11-21T15:52:39.204000+02:00
arik-rainish-lag        OK      2026-11-20T20:22:04.752000+02:00
arik-rainish-health     ALARM   2026-11-21T15:52:39.204000+02:00
$ kubectl annotate scaledobject consumer -n pipeline autoscaling.keda.sh/paused-replicas-
scaledobject.keda.sh/consumer annotated
$ sleep 60; kubectl get hpa -n pipeline
NAME                REFERENCE             TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-consumer   Deployment/consumer   31200m/1k (avg)   2         5         5          78s
$ make query SQL=scripts/gaps.sql
symbol   | rows  | missing
---------+-------+--------
ADAUSDT  | 1339  | 0
AVAXUSDT | 1306  | 0
BNBUSDT  | 8987  | 0
BTCUSDT  | 36104 | 0
DOGEUSDT | 3930  | 0
ETHUSDT  | 37354 | 0
LINKUSDT | 1863  | 0
SOLUSDT  | 10883 | 0
XRPUSDT  | 7114  | 0
(9 rows)
```

The ALARM email came at 13:52:39 UTC and the OK email at 13:57:39.

With no consumer the freshness alarm fired and I got an email, without reading any log. When the consumers came back, KEDA scaled to 5, the backlog from the pause was read within about a minute, and the alarm cleared. Nothing was lost (proof 8 checks the whole table).

The lag alarm stayed `OK`. The two MSK metrics for the same minutes:

```
$ aws cloudwatch get-metric-statistics --namespace AWS/Kafka --metric-name EstimatedMaxTimeLag --dimensions Name="Cluster Name",Value=$(aws kafka list-clusters-v2 --query 'ClusterInfoList[0].ClusterName' --output text) Name="Consumer Group",Value=trades-writer Name=Topic,Value=trades --start-time 2026-11-21T13:47:00Z --end-time 2026-11-21T13:59:00Z --period 60 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
2026-11-21T15:47:00+02:00       0.0
2026-11-21T15:48:00+02:00       0.0
2026-11-21T15:49:00+02:00       0.0
2026-11-21T15:50:00+02:00       0.0
2026-11-21T15:51:00+02:00       0.0
2026-11-21T15:52:00+02:00       0.0
2026-11-21T15:53:00+02:00       0.0
2026-11-21T15:54:00+02:00       0.0
2026-11-21T15:55:00+02:00       0.0
2026-11-21T15:56:00+02:00       0.0
2026-11-21T15:57:00+02:00       1.0
2026-11-21T15:58:00+02:00       0.0
$ # same command with --metric-name MaxOffsetLag
2026-11-21T15:47:00+02:00       40300.0
2026-11-21T15:48:00+02:00       50958.0
2026-11-21T15:49:00+02:00       65198.0
2026-11-21T15:50:00+02:00       77146.0
2026-11-21T15:51:00+02:00       85922.0
2026-11-21T15:52:00+02:00       95324.0
2026-11-21T15:53:00+02:00       105328.0
2026-11-21T15:54:00+02:00       114230.0
2026-11-21T15:55:00+02:00       121312.0
2026-11-21T15:56:00+02:00       286.0
2026-11-21T15:57:00+02:00       74.0
2026-11-21T15:58:00+02:00       60.0
```

### 4b. The same test with the backlog alarm

I repeated proof 4 on 22.11, after adding the backlog alarm:

```
$ date -u; kubectl annotate scaledobject consumer -n pipeline autoscaling.keda.sh/paused-replicas="0" --overwrite
Sun Nov 22 17:23:32 UTC 2026
scaledobject.keda.sh/consumer annotated
$ for i in $(seq 10); do date -u +%T; aws cloudwatch describe-alarms --alarm-name-prefix arik-rainish --alarm-types MetricAlarm CompositeAlarm --query '[MetricAlarms[].[AlarmName,StateValue], CompositeAlarms[].[AlarmName,StateValue]]' --output text; sleep 60; done
17:23:51
arik-rainish-backlog    OK
arik-rainish-freshness  OK
arik-rainish-lag        OK
arik-rainish-health     OK
[...]
17:31:04
arik-rainish-backlog    ALARM
arik-rainish-freshness  OK
arik-rainish-lag        OK
arik-rainish-health     ALARM
17:32:05
arik-rainish-backlog    ALARM
arik-rainish-freshness  OK
arik-rainish-lag        OK
arik-rainish-health     ALARM
17:33:07
arik-rainish-backlog    ALARM
arik-rainish-freshness  ALARM
arik-rainish-lag        OK
arik-rainish-health     ALARM
$ date -u; kubectl annotate scaledobject consumer -n pipeline autoscaling.keda.sh/paused-replicas-
Sun Nov 22 17:34:27 UTC 2026
scaledobject.keda.sh/consumer annotated
$ for a in backlog freshness; do aws cloudwatch describe-alarm-history --alarm-name arik-rainish-$a --history-item-type StateUpdate --start-date 2026-11-22T17:15:00Z --query 'AlarmHistoryItems[].[AlarmName,Timestamp,HistorySummary]' --output text; done
arik-rainish-backlog    2026-11-22T19:36:25.996000+02:00        Alarm updated from ALARM to OK
arik-rainish-backlog    2026-11-22T19:30:25.992000+02:00        Alarm updated from OK to ALARM
arik-rainish-backlog    2026-11-22T19:22:25.996000+02:00        Alarm updated from INSUFFICIENT_DATA to OK
arik-rainish-freshness  2026-11-22T19:36:39.201000+02:00        Alarm updated from ALARM to OK
arik-rainish-freshness  2026-11-22T19:32:39.202000+02:00        Alarm updated from OK to ALARM
$ make query SQL=scripts/gaps.sql
symbol   | rows  | missing
---------+-------+--------
ADAUSDT  | 115   | 0
AVAXUSDT | 384   | 0
BNBUSDT  | 2401  | 0
BTCUSDT  | 22483 | 0
DOGEUSDT | 968   | 0
ETHUSDT  | 10337 | 0
LINKUSDT | 648   | 0
SOLUSDT  | 2166  | 0
XRPUSDT  | 1217  | 0
(9 rows)
```

The backlog alarm fired 7 minutes after the consumers stopped (17:30:25 UTC), and the ALARM email named it as the trigger. The freshness alarm followed at 17:32:39. The lag alarm stayed `OK` again. Both cleared about 2 minutes after the consumers came back, and the OK email came at 17:36:39.

### 5. A producer dies

```
$ kubectl delete -n pipeline $(kubectl get pod -n pipeline -l app.kubernetes.io/name=producer -o name | head -1)
pod "producer-65c99b6d5b-8fznq" deleted from pipeline namespace
$ sleep 60; kubectl get pods -n pipeline -l app.kubernetes.io/name=producer
NAME                        READY   STATUS    RESTARTS   AGE
producer-65c99b6d5b-dx8mb   1/1     Running   0          83s
producer-65c99b6d5b-vsh9j   1/1     Running   0          20h
$ kubectl logs -n pipeline -l app.kubernetes.io/name=producer --since=2m --tail=-1 | grep -E 'connected|backfill'
2026-11-21 14:29:22,384 INFO connected to Binance
$ make query SQL=scripts/gaps.sql
symbol   | rows  | missing
---------+-------+--------
ADAUSDT  | 736   | 0
AVAXUSDT | 796   | 0
BNBUSDT  | 7979  | 0
BTCUSDT  | 27022 | 0
DOGEUSDT | 2231  | 0
ETHUSDT  | 25266 | 0
LINKUSDT | 1025  | 0
SOLUSDT  | 5748  | 0
XRPUSDT  | 2362  | 0
(9 rows)
```

The second producer kept sending while the replacement started. On shutdown a producer flushes what it still holds. This is `dx8mb` being deleted later the same day:

```
$ kubectl logs -n pipeline -f pod/producer-65c99b6d5b-dx8mb --tail=2
2026-11-21 14:29:22,384 INFO connected to Binance
[...]
2026-11-21 15:49:09,009 INFO shutdown: flushed, 0 messages not delivered
```

### 5b. Binance drops the connection

When a producer reconnects, it compares each trade id with the last one it saw for that symbol. A jump means missed trades, and it fetches them from Binance's REST API of past trades before sending the new ones.

Binance documents that a connection lasts at most 24 hours, but producer `vsh9j` had no disconnect in its log 25 hours after it connected. So I forced one: I blocked port 9443, the WebSocket port, inside one producer pod for 60 s, and left port 443 open for the REST API. The producer container runs as non-root with no capabilities, so the block runs in an ephemeral debug container that shares the pod's network:

```
$ echo '{"securityContext":{"runAsUser":0,"runAsNonRoot":false,"capabilities":{"add":["NET_ADMIN"]}}}' > ~/netadmin-5b.json
$ kubectl debug -n pipeline -it producer-f8fcdf74f-5nx44 --image=nicolaka/netshoot:v0.13 --profile=general --custom=$HOME/netadmin-5b.json -- bash
producer-f8fcdf74f-5nx44:~# date -u; iptables -A OUTPUT -p tcp --dport 9443 -j REJECT --reject-with tcp-reset; sleep 60; iptables -D OUTPUT -p tcp --dport 9443 -j REJECT --reject-with tcp-reset; date -u; iptables -S OUTPUT
Sun Nov 22 16:50:05 UTC 2026
Sun Nov 22 16:51:05 UTC 2026
-P OUTPUT ACCEPT
```

The producer's log, followed in a second terminal (the repeated connect errors are cut short):

```
$ kubectl logs -n pipeline -f producer-f8fcdf74f-5nx44 --since=1m
2026-11-22 16:50:05,668 WARNING connection lost (no close frame received or sent); reconnecting in 1.0s
2026-11-22 16:50:06,681 WARNING connection lost (Multiple exceptions: [Errno 111] Connect call failed ('57.181.81.8', 9443), [...]); reconnecting in 1.1s
2026-11-22 16:50:07,742 WARNING connection lost ([...]); reconnecting in 2.4s
2026-11-22 16:50:10,130 WARNING connection lost ([...]); reconnecting in 4.6s
2026-11-22 16:50:14,697 WARNING connection lost ([...]); reconnecting in 10.7s
2026-11-22 16:50:25,432 WARNING connection lost ([...]); reconnecting in 16.3s
2026-11-22 16:50:41,746 WARNING connection lost ([...]); reconnecting in 24.4s
2026-11-22 16:51:06,903 INFO connected to Binance
2026-11-22 16:51:07,235 INFO backfilled 352 trades for BNBUSDT
2026-11-22 16:51:10,449 INFO backfilled 2146 trades for BTCUSDT
2026-11-22 16:51:10,715 INFO backfilled 97 trades for DOGEUSDT
2026-11-22 16:51:10,995 INFO backfilled 809 trades for ETHUSDT
2026-11-22 16:51:11,272 INFO backfilled 48 trades for AVAXUSDT
2026-11-22 16:51:11,544 INFO backfilled 175 trades for XRPUSDT
2026-11-22 16:51:11,814 INFO backfilled 246 trades for SOLUSDT
2026-11-22 16:51:12,084 INFO backfilled 49 trades for LINKUSDT
2026-11-22 16:51:17,304 INFO backfilled 14 trades for ADAUSDT
$ kubectl get pod -n pipeline producer-f8fcdf74f-5nx44
NAME                       READY   STATUS    RESTARTS   AGE
producer-f8fcdf74f-5nx44   1/1     Running   0          147m
```

The producer retried with backoff and kept its heartbeat fresh while it waited, so liveness did not restart it. Its next retry, already scheduled, came two seconds after the block was removed. It reconnected and backfilled 3,936 trades across all 9 symbols; the largest, 2,146 BTC trades, took about 3 seconds. The `backfilled` lines and `RESTARTS 0` are the proof.

The gap check over the hour around it (`gaps.sql` with 60 minutes instead of 10) showed 0 missing, but that alone proves little here, because the other producer kept sending everything.

This ran before commit `92e0803` (included in the deployed `86ec2b6`), which retries a backfill up to 3 times when the REST history is still behind the stream; that retry is not shown.

### 6. Freshness over 24 hours

```
$ aws cloudwatch get-metric-statistics --namespace TradesPipeline --metric-name FreshnessSeconds --start-time $(date -u -d '-24 hours' +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 3600 --statistics Maximum Average --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum,Average]' --output text
2026-11-20T21:23:00+02:00       1.674863        1.222443751803752
2026-11-20T22:23:00+02:00       1.593616        1.2213734402877698
2026-11-20T23:23:00+02:00       2.112771        1.2088808651362983
2026-11-21T00:23:00+02:00       1.50829 1.1925001771428576
2026-11-21T01:23:00+02:00       1.418428        1.1725842457142859
2026-11-21T02:23:00+02:00       1.42216 1.1788109014285717
2026-11-21T03:23:00+02:00       1.760326        1.1750432471428571
2026-11-21T04:23:00+02:00       1.401617        1.1896001848137536
2026-11-21T05:23:00+02:00       2.681741        1.2141717933425797
2026-11-21T06:23:00+02:00       1.425799        1.2178811942028986
2026-11-21T07:23:00+02:00       1.373511        1.210273515151515
2026-11-21T08:23:00+02:00       1.533721        1.2189681170520228
2026-11-21T09:23:00+02:00       1.444457        1.2030801035971224
2026-11-21T10:23:00+02:00       1.481477        1.2019181928057547
2026-11-21T11:23:00+02:00       1.379183        1.1923570472779366
2026-11-21T12:23:00+02:00       1.44419 1.1830190955777466
2026-11-21T13:23:00+02:00       2.051172        1.1949406981402002
2026-11-21T14:23:00+02:00       47.988338       1.5869344758713142
2026-11-21T15:23:00+02:00       696.244097      5.759531021103895
2026-11-21T16:23:00+02:00       1.581055        1.2018629096126257
2026-11-21T17:23:00+02:00       2.898516        1.195656117310443
2026-11-21T18:23:00+02:00       1.350924        1.1839328145506423
2026-11-21T19:23:00+02:00       1.500961        1.171242851851852
2026-11-21T20:23:00+02:00       1.490199        1.164059827142857
$ aws cloudwatch describe-alarm-history --alarm-name arik-rainish-freshness --history-item-type StateUpdate --start-date $(date -u -d '-24 hours' +%FT%TZ) --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
2026-11-21T15:57:39.202000+02:00        Alarm updated from ALARM to OK
2026-11-21T15:52:39.204000+02:00        Alarm updated from OK to ALARM
```

Each row is one hour: the worst freshness and the average, in seconds. In 22 of the 24 hours the worst value stayed under 3 s. The two exceptions are my own tests: the kill -9 in proof 3b (48 s, no alarm, because it lasted less than the 3 minutes the alarm needs) and the paused consumers in proof 4 (696 s, the one ALARM in the history).

### 7. The final version

Commit `86ec2b6`. Its first deploy got stuck (see "Assumptions and shortcuts"); this is the second `make deploy`, at about 19:52 UTC on 22.11, after `maxUnavailable` was set back to 0. The producer pods shown come from the first rollout, released with the temporary patch. It ends by waiting for the producer rollout, and both producers run on different nodes:

```
$ make deploy 2>&1 | tail -2
kubectl -n pipeline rollout status deploy/producer --timeout=300s
deployment "producer" successfully rolled out
$ kubectl -n pipeline get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,SURGE:.spec.strategy.rollingUpdate.maxSurge,UNAVAIL:.spec.strategy.rollingUpdate.maxUnavailable
NAME       IMAGE                                                                         SURGE   UNAVAIL
consumer   092988563851.dkr.ecr.eu-north-1.amazonaws.com/arik-rainish-consumer:86ec2b6   1       0
producer   092988563851.dkr.ecr.eu-north-1.amazonaws.com/arik-rainish-producer:86ec2b6   1       0
$ kubectl -n pipeline get pods -l app.kubernetes.io/name=producer -o wide
NAME                        READY   STATUS    RESTARTS   AGE   IP            NODE
producer-744bfb8547-68fhp   1/1     Running   0          41m   10.0.16.250   ip-10-0-6-235.eu-north-1.compute.internal
producer-744bfb8547-vmtkw   1/1     Running   0          37m   10.0.35.8     ip-10-0-34-105.eu-north-1.compute.internal
$ make query SQL=scripts/duplicates.sql && sed "s/10 minutes/60 minutes/" scripts/gaps.sql | kubectl -n pipeline exec -i deploy/consumer -- python query.py && make health
symbol | trade_id | count
-------+----------+------
(0 rows)
symbol   | rows  | missing
---------+-------+--------
ADAUSDT  | 1066  | 0
AVAXUSDT | 1250  | 0
BNBUSDT  | 8934  | 0
BTCUSDT  | 71200 | 0
DOGEUSDT | 3892  | 0
ETHUSDT  | 27509 | 0
LINKUSDT | 2208  | 0
SOLUSDT  | 9258  | 0
XRPUSDT  | 4982  | 0
(9 rows)
OK
```

The gap check covers the hour with both producer rollouts of that evening, the stuck one included.

### 8. The whole table

After everything above, the gap check over the whole table, since the first trade on 20.11:

```
$ time (echo "SELECT now() AS checked_at, symbol, count(*) AS rows, max(trade_id) - min(trade_id) + 1 - count(*) AS missing FROM trades GROUP BY symbol ORDER BY symbol;" | kubectl -n pipeline exec -i deploy/consumer -- python query.py)
checked_at                       | symbol   | rows     | missing
---------------------------------+----------+----------+--------
2026-11-22 20:26:33.505418+00:00 | ADAUSDT  | 195956   | 0
2026-11-22 20:26:33.505418+00:00 | AVAXUSDT | 306175   | 0
2026-11-22 20:26:33.505418+00:00 | BNBUSDT  | 1618940  | 0
2026-11-22 20:26:33.505418+00:00 | BTCUSDT  | 10674882 | 0
2026-11-22 20:26:33.505418+00:00 | DOGEUSDT | 768427   | 0
2026-11-22 20:26:33.505418+00:00 | ETHUSDT  | 6839359  | 0
2026-11-22 20:26:33.505418+00:00 | LINKUSDT | 477246   | 0
2026-11-22 20:26:33.505418+00:00 | SOLUSDT  | 1777402  | 0
2026-11-22 20:26:33.505418+00:00 | XRPUSDT  | 984216   | 0
(9 rows)

real    0m18.427s
```

23,642,603 trades since 20.11 18:25 UTC, and no trade id missing for any symbol. The query reads the whole table, so it takes about 20 seconds.

## Design decisions

- Kafka holds every trade twice by design, one copy from each producer. Duplicates are removed in the database by the primary key, not in Kafka.
- Topic key is the symbol, so BTC, the busiest symbol, always lands on one partition. At today's rate one consumer keeps up with it.
- The table has one column beyond the six in the assignment: `ingested_at`, the time of the insert. `scripts/freshness.sql` uses it.

## Assumptions and shortcuts

### Sizing and cost

- One NAT Gateway for all three AZs. Production: one per AZ, so an AZ failure does not cut egress.
- RDS is single-AZ (`db.t4g.micro`). Production: Multi-AZ.
- No RDS Proxy. With one small instance and a few connections it would add cost without a gain.
- MSK is 3 `kafka.t3.small` brokers, topic `trades` with 6 partitions, replication factor 3, `min.insync.replicas=2`, retention 24 hours.
- The node group is 2 nodes, `max_size` 3, with no node autoscaler. Five consumers and two producers fit on two `t3.medium` nodes. The two producers never share a node (required pod anti-affinity), so if a node fails, its producer stays `Pending` until the node group replaces the node, while the other producer keeps sending. During a rollout only pods of the same revision count for that rule, so a new producer starts next to an old one, and an old one is stopped only after the new one has been Ready for 30 s. Two producers run throughout a normal rollout.
- No automated RDS backups (retention 0, so destroy leaves nothing). Production: 7+ days with point-in-time restore.
- RDS storage starts at 20 GB and can grow to 100 GB (`max_allocated_storage`). There is no retention policy, so the table keeps growing. Production: partition by day and drop old partitions.

### Security

- The `trades_app` password is not rotated. The master password is managed and rotated by RDS. Production: a rotation schedule for the app secret too.
- The EKS API endpoint is public to 0.0.0.0/0, so you can reach it. Production: a CIDR allow-list or a private endpoint.
- Pods get AWS access through IRSA, not EKS Pod Identity, because the account's permission boundary does not allow `eks-auth:AssumeRoleForPodIdentity`.
- The DB connection uses `sslmode=require`: encrypted, but the server certificate is not verified. Production: `verify-full` with the RDS CA bundle.
- Cluster-admin belongs to the principal that runs `terraform apply` (the EKS module's creator entry), so an apply by another principal moves it to them. Production: turn that off and list the admin roles explicitly.
- There is no NetworkPolicy: MSK and RDS accept the node security group, so any pod could reach them at network level; both still require authentication.

### Failure modes with no alarm

- No dead-letter handling. A message that is not valid JSON would crash the consumer, and after the restart it would read the same message again and crash again. Binance messages are well-formed in practice. Production: skip and count bad messages, or send them to a DLQ topic.
- A backfill that fails (a 429 from Binance, or a REST history that is still behind the stream after 3 more tries) is only logged and counted in the producer (`gaps_unfilled`). There is no alarm on gaps; `scripts/gaps.sql` is the check. Production: publish that counter as a metric and alarm on it.
- An MSK outage longer than 5 minutes loses trades. The producer drops a message it could not deliver within 5 minutes (librdkafka's `message.timeout.ms` default), and after more than 100 failed deliveries in a row it exits. Both producers are in the same position. If only one partition is unavailable that long, its messages are dropped while deliveries to the other partitions keep resetting the counter, and no alarm sees it. Production: buffer to local disk, or stop reading the WebSocket while Kafka is down and backfill after it.
- A backfill runs before the producer reads the next WebSocket message. In proof 5b the longest one took about 3 seconds. A much longer one could let the WebSocket keepalive close the connection; the producer then reconnects and backfills again.
- A producer keeps the last trade id of each symbol in memory only. After a restart it cannot see what it missed while it was down, and relies on the other producer for that window. If both are down at the same moment (the same bug in both, or the MSK outage above), the window is lost and no alarm sees it; the whole-table check in proof 8 would show it. Production: on start, read the last trade ids back from the topic and backfill from there.
- A pod is Ready once the process has started, not once it has delivered a trade. A release that starts but cannot reach Kafka or Binance would still replace the old pods, and the alarms would be the first signal. Production: readiness tied to the first delivered message.
- If a node goes NotReady and is not replaced, or is drained with no spare node, one producer runs alone until a node is back, and no alarm watches the number of producers. Production: an alarm on available producer replicas, and node auto repair.
- MSK keeps its default `unclean.leader.election.enable=true`. It matters only if every in-sync replica of a partition is lost at once. Production: set it to false.
- Logs stay in the pods: EKS control-plane logging is off (so destroy leaves no log group), and pod logs are not shipped. There is no alarm on MSK or RDS disk usage either. Production: Fluent Bit to CloudWatch, audit logs, and disk alarms.

### Tooling and operations

- Images are built and pushed by a local script (`make images`), not by CI. Production: a pipeline with OIDC to AWS.
- The S3 backend uses `dynamodb_table`, which Terraform now marks deprecated. I kept it because the lock table was provided.
- EKS add-on versions are not pinned; the module takes the most recent version for 1.35, so a later apply can update them.
- The DB schema is created by a Helm pre-install/pre-upgrade Job (`db_init.py`). It is the only workload that reads the master secret. It is `CREATE TABLE IF NOT EXISTS`, not a migration tool, because there is one table.
- `docker-compose.yml` runs the same images locally without AWS (Kafka without IAM, a local Postgres). It is for development only. I also used it to test the backfill before AWS: with two producers (`docker compose up --scale producer=2`) cut off the network for 60 s, each one backfilled all 9 symbols (for example 5,267 BTC trades), and `gaps.sql` showed 0 missing.
- Pod anti-affinity is symmetric: the running pods' own rules also block a new pod. Moving from plain anti-affinity (commit `f264575`) to the `matchLabelKeys` version (`86ec2b6`) got the rollout stuck, so I let that one rollout go with `maxUnavailable: 1` and set it back to 0. A rollback across that change would get stuck the same way.
- There are no automated tests in the repo; `terraform validate`, `helm lint` and the proofs above are the checks.

## Repo layout

```
app/producer/       producer.py, healthcheck.py, Dockerfile
app/consumer/       consumer.py, db_init.py, query.py, healthcheck.py, Dockerfile
infra/              Terraform: VPC, EKS, MSK, RDS, ECR, IAM, alarms
apps/               Terraform: KEDA and the pipeline Helm release
apps/chart/pipeline Helm chart: producer, consumer, KEDA ScaledObject, db-init Job, PDBs
scripts/            build-push.sh, verify-clean.sh, the three proof queries
Makefile            preflight, images, deploy, destroy, verify-clean, health, query, kubeconfig
docker-compose.yml  local run
```
