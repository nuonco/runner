import json
import os
import time

import urllib3
import cfnresponse
from botocore.exceptions import ClientError

http = urllib3.PoolManager()

MAX_RETRIES = 5
BASE_DELAY = 1.75


def auth_header():
    """Bearer token for the phone-home endpoint, or {} when not enrolled.

    Fetched at invocation, not baked into the template: the template is downloaded
    unauthenticated from S3 via the quick-link, so it may only carry the secret's
    location. This also means rotation needs no re-apply. Absent env vars mean the
    stack predates phone-home auth, so one script serves enrolled and unenrolled.
    """
    arn = os.environ.get("NUON_PHONE_HOME_SECRET_ARN")
    if not arn:
        return {}

    try:
        import boto3

        client = boto3.client(
            "secretsmanager",
            region_name=os.environ["NUON_PHONE_HOME_SECRET_REGION"],
        )
        secret = client.get_secret_value(SecretId=arn)["SecretString"]
        token = json.loads(secret).get(os.environ["NUON_PHONE_HOME_ID"])
    except ClientError as e:
        error = e.response.get("Error", {})
        metadata = e.response.get("ResponseMetadata", {})
        print(
            "Unable to read phone home token:",
            json.dumps(
                {
                    "type": type(e).__name__,
                    "operation": e.operation_name,
                    "code": error.get("Code"),
                    "message": error.get("Message"),
                    "http_status": metadata.get("HTTPStatusCode"),
                    "request_id": metadata.get("RequestId"),
                    "retry_attempts": metadata.get("RetryAttempts"),
                },
                sort_keys=True,
            ),
        )
        return {}
    except Exception as e:
        # Not fatal: send no header and let the API decide, so there is one place
        # that determines the outcome. Log the type only — the message can echo the
        # secret's contents.
        print("Unable to read phone home token:", type(e).__name__)
        return {}

    if not token:
        print("No phone home token for this stack version")
        return {}

    return {"Authorization": "Bearer " + token}


def lambda_handler(event, context):
    # Start with all fields from the event, then flatten ResourceProperties in.
    data = event.copy()
    props = data.pop("ResourceProperties", None)

    props["request_type"] = event["RequestType"]

    encoded_data = json.dumps(props).encode("utf-8")
    url = props["url"]

    headers = {"Content-Type": "application/json"}
    headers.update(auth_header())

    last_error = None
    for attempt in range(MAX_RETRIES):
        try:
            response = http.request(
                "POST",
                url,
                body=encoded_data,
                headers=headers,
            )
            if 200 <= response.status < 300:
                print("Response: ", response.data)
                cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
                return

            last_error = f"HTTP {response.status}: {response.data}"
            print(f"Attempt {attempt + 1}/{MAX_RETRIES} failed: {last_error}")

            # A 4xx is a verdict, not a blip. Retrying a 401 or a 409 burns ~30s of
            # Lambda time and cannot change the answer.
            if 400 <= response.status < 500:
                break
        except Exception as e:
            last_error = str(e)
            print(f"Attempt {attempt + 1}/{MAX_RETRIES} error: {last_error}")

        if attempt < MAX_RETRIES - 1:
            delay = BASE_DELAY * (2**attempt)
            print(f"Retrying in {delay}s...")
            time.sleep(delay)

    print("Giving up. Error: ", last_error)

    # Fail open on anything but Create. A rejected or unreachable phone home during
    # an Update is a control-plane decision, and reporting FAILED would drop the
    # customer's stack into UPDATE_ROLLBACK over infrastructure Nuon does not own.
    # Nuon keeps stale outputs and records the rejection in its own metrics instead.
    #
    # A first-ever Create still fails loudly: an install that never received stack
    # outputs is genuinely broken and should say so.
    if event["RequestType"] == "Create":
        cfnresponse.send(event, context, cfnresponse.FAILED, {"Error": last_error})
    else:
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
