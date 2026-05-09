import json
import logging
import os
from urllib import request, parse, error

import boto3

STEAM_STORE_BASE_URL = os.environ["STEAM_STORE_BASE_URL"]
BUCKET_NAME = os.environ["BUCKET_NAME"]

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger(__name__)

s3 = boto3.client("s3")


def get_capsule_image_from_steam_store(steam_game_id):
    params = parse.urlencode({"appids": steam_game_id})
    url = f"{STEAM_STORE_BASE_URL}/api/appdetails?{params}"

    with request.urlopen(url) as response:
        if response.status != 200:
            raise error.HTTPError(url, response.status, "Failed to fetch game data", {}, None)
        data = json.loads(response.read())

    capsule_image_url = data[str(steam_game_id)]["data"]["capsule_image"]

    with request.urlopen(capsule_image_url) as img_response:
        if img_response.status != 200:
            raise error.HTTPError(capsule_image_url, img_response.status, "Failed to fetch capsule image", {}, None)
        return img_response.read()


def handler(event, context):
    failed_message_ids = []

    for record in event["Records"]:
        try:
            message = json.loads(record["body"])
            logger.info("Processing message: %s", message)

            if "game_data" not in message or "steam_game_id" not in message["game_data"]:
                logger.error("Unexpected message structure, skipping record %s: %s", record["messageId"], message)
                continue

            steam_game_id = message["game_data"]["steam_game_id"]

            capsule_image = get_capsule_image_from_steam_store(steam_game_id)

            s3.put_object(
                Bucket=BUCKET_NAME,
                Key=f"{steam_game_id}-capsule.jpg",
                Body=capsule_image,
                ContentType="image/jpeg",
            )

            logger.info("Uploaded capsule image for game %s", steam_game_id)
        except Exception as e:
            logger.error("Failed to process record %s: %s. Body: %s", record["messageId"], e, record["body"], exc_info=True)
            failed_message_ids.append({"itemIdentifier": record["messageId"]})

    logger.info("Processed %d records, %d failed", len(event["Records"]), len(failed_message_ids))
    return {"batchItemFailures": failed_message_ids}
