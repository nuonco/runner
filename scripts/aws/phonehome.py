import json

import urllib3
import cfnresponse

http = urllib3.PoolManager()


def lambda_handler(event, context):
    if event["RequestType"].startswith("DeleteFunction"):
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {})

    props = event["ResourceProperties"]
    
    # Start with all fields from the event
    data = event.copy()
    # Remove ResourceProperties since we'll flatten those separately
    props = data.pop("ResourceProperties", None)
    
    encoded_data = json.dumps(props).encode("utf-8")
    url = props["url"]

    try:
        response = http.request(
            "POST",
            url,
            body=encoded_data,
            headers={"Content-Type": "application/json"},
        )
        print("Response: ", response.data)
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
    except Exception as e:
        print("Error: ", str(e))
        # It's OK if notifying Nuon fails on deletion
        if event["RequestType"] in ["Create", "Update"]:
            cfnresponse.send(event, context, cfnresponse.FAILED, {"Error": str(e)})
        else:
            cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
