import json
import time

import urllib3
import cfnresponse

http = urllib3.PoolManager()

MAX_RETRIES = 3
BASE_DELAY = 1


def lambda_handler(event, context):
    props = event["ResourceProperties"]

    # Start with all fields from the event
    data = event.copy()
    # Remove ResourceProperties since we'll flatten those separately
    props = data.pop("ResourceProperties", None)

    props["request_type"] = event["RequestType"]

    encoded_data = json.dumps(props).encode("utf-8")
    url = props["url"]

    last_error = None
    for attempt in range(MAX_RETRIES):
        try:
            response = http.request(
                "POST",
                url,
                body=encoded_data,
                headers={"Content-Type": "application/json"},
            )
            if 200 <= response.status < 300:
                print("Response: ", response.data)
                cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
                return

            last_error = f"HTTP {response.status}: {response.data}"
            print(f"Attempt {attempt + 1}/{MAX_RETRIES} failed: {last_error}")
        except Exception as e:
            last_error = str(e)
            print(f"Attempt {attempt + 1}/{MAX_RETRIES} error: {last_error}")

        if attempt < MAX_RETRIES - 1:
            delay = BASE_DELAY * (2 ** attempt)
            print(f"Retrying in {delay}s...")
            time.sleep(delay)

    print("All retries exhausted. Error: ", last_error)
    if event["RequestType"] in ["Create", "Update"]:
        cfnresponse.send(event, context, cfnresponse.FAILED, {"Error": last_error})
    else:
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
