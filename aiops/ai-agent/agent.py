"""
AI Agent — LangChain + AWS Bedrock (Claude Sonnet 4.5).
Polls SQS intelliops-anomalies every 30 seconds, invokes the ReAct agent
to diagnose and remediate each anomaly, then posts a summary to Slack.
"""
import os
import json
import time
import logging
import requests
import boto3
from langchain_aws import ChatBedrock
from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain_core.prompts import ChatPromptTemplate

from tools import (
    query_prometheus,
    query_loki,
    restart_pod,
    scale_deployment,
    get_events,
    get_pod_logs,
    get_hpa_status,
    rollback_argocd,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

AWS_REGION     = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
SQS_QUEUE_URL  = os.getenv("SQS_QUEUE_URL", "")
SLACK_WEBHOOK  = os.getenv("SLACK_WEBHOOK_URL", "")
BEDROCK_MODEL  = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-5")
POLL_INTERVAL  = int(os.getenv("POLL_INTERVAL_SECONDS", "30"))

TOOLS = [
    query_prometheus,
    query_loki,
    restart_pod,
    scale_deployment,
    get_events,
    get_pod_logs,
    get_hpa_status,
    rollback_argocd,
]

SYSTEM_PROMPT = """You are an AIOps auto-remediation agent for the IntelliOps Sherlock platform.
You receive anomaly events from the anomaly detection system and must:
1. Diagnose the root cause using available observability tools
2. Take the minimum necessary remediation action
3. Verify the action resolved the issue
4. Produce a concise summary of what happened and what you did

Rules:
- Always query metrics and logs BEFORE taking any action
- Prefer soft actions (scale up, restart pod) over destructive ones (rollback)
- Only rollback if error rate is above 10% and increasing
- Never scale a deployment below 1 replica
- Target namespaces for services: apps namespace for microservices, aiops-demo for AIOps components
- If unsure, query more data rather than acting
"""

PROMPT = ChatPromptTemplate.from_messages([
    ("system", SYSTEM_PROMPT),
    ("human",  "{input}"),
    ("placeholder", "{agent_scratchpad}"),
])


def build_agent() -> AgentExecutor:
    llm = ChatBedrock(
        model_id=BEDROCK_MODEL,
        region_name=AWS_REGION,
        model_kwargs={"max_tokens": 4096, "temperature": 0},
    )
    agent = create_tool_calling_agent(llm, TOOLS, PROMPT)
    return AgentExecutor(
        agent=agent,
        tools=TOOLS,
        verbose=True,
        max_iterations=10,
        handle_parsing_errors=True,
    )


def post_slack(message: str, severity: str = "warning"):
    if not SLACK_WEBHOOK:
        log.warning("SLACK_WEBHOOK_URL not set — skipping Slack notification")
        return
    colour = {"critical": "#FF0000", "warning": "#FFA500", "info": "#36A64F"}.get(severity, "#36A64F")
    payload = {
        "attachments": [{
            "color":   colour,
            "title":   "AIOps Auto-Remediation",
            "text":    message,
            "footer":  "intelliops-sherlock | ai-agent",
            "ts":      int(time.time()),
        }]
    }
    try:
        requests.post(SLACK_WEBHOOK, json=payload, timeout=10)
    except Exception as e:
        log.error("Slack notification failed: %s", e)


def process_message(executor: AgentExecutor, body: str):
    try:
        event = json.loads(body)
        severity = event.get("severity", "warning")
        features = event.get("features", {})
        score    = event.get("anomaly_score", 0.0)

        input_text = (
            f"ANOMALY DETECTED — severity={severity}, score={score:.3f}\n"
            f"Metrics snapshot: {json.dumps(features, indent=2)}\n\n"
            f"Please investigate and remediate."
        )
        log.info("Processing anomaly: %s", input_text[:200])

        result = executor.invoke({"input": input_text})
        output = result.get("output", "No output from agent")
        log.info("Agent output: %s", output)

        slack_msg = f"*Anomaly (score={score:.3f}, severity={severity})*\n{output}"
        post_slack(slack_msg, severity)
    except Exception as e:
        log.error("Failed to process SQS message: %s", e)
        post_slack(f"AI Agent error processing anomaly: {e}", "warning")


def poll_sqs(executor: AgentExecutor):
    if not SQS_QUEUE_URL:
        log.error("SQS_QUEUE_URL is not set — cannot poll queue")
        return

    sqs = boto3.client("sqs", region_name=AWS_REGION)
    log.info("Polling SQS queue: %s (interval=%ds)", SQS_QUEUE_URL, POLL_INTERVAL)

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20,
                VisibilityTimeout=300,
            )
            messages = response.get("Messages", [])
            for msg in messages:
                process_message(executor, msg["Body"])
                sqs.delete_message(
                    QueueUrl=SQS_QUEUE_URL,
                    ReceiptHandle=msg["ReceiptHandle"],
                )
        except Exception as e:
            log.error("SQS poll error: %s", e)
            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    log.info("Starting AI Agent (model=%s)", BEDROCK_MODEL)
    executor = build_agent()
    post_slack("AI Agent started — monitoring SQS for anomalies", "info")
    poll_sqs(executor)
