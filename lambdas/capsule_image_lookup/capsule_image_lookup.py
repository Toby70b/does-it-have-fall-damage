import boto3
import gzip
import json
import logging
import os
import requests

STEAM_STORE_BASE_URL = os.environ["STEAM_STORE_BASE_URL"]
BUCKET_NAME = os.environ["BUCKET_NAME"]

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger(__name__)

s3 = boto3.client("s3")

def get_capsule_image_from_steam_store(steam_game_id):
    steam_game_data_response = requests.get(
        f"{STEAM_STORE_BASE_URL}/api/appdetails",
        params={"appids": steam_game_id, "filters": "basic"}
    )
    steam_game_data_response.raise_for_status()

    capsule_image_url = steam_game_data_response.json()[steam_game_id]["data"]["capsule_image"]
    capsule_image_response = requests.get(capsule_image_url)
    capsule_image_response.raise_for_status()

    return capsule_image_response.content


def handler(event, context):
    failed_message_ids = []

    for record in event["Records"]:
        try:
            message = json.loads(record["body"])
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
            logger.error("Failed to process record %s: %s", record["messageId"], e)
            failed_message_ids.append({"itemIdentifier": record["messageId"]})

    logger.info("Processed %d records, %d failed", len(event["Records"]), len(failed_message_ids))
    return {"batchItemFailures": failed_message_ids}

