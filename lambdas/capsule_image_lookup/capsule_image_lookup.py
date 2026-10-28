import json
import logging
import os
from urllib import request, parse, error

import boto3

STEAM_STORE_BASE_URL = os.environ.get("STEAM_STORE_BASE_URL", "https://store.steampowered.com")
BUCKET_NAME = os.environ["BUCKET_NAME"]

# Steam's store edge 403s urllib's default UA; send a browser-like one.
_HEADERS = {"User-Agent": "Mozilla/5.0"}

# appdetails image fields, in order of preference. capsule_image/header_image
# are null for many newer apps (whose art lives under a hashed store_item_assets
# path we can't construct), so fall back through to whatever is populated.
_IMAGE_FIELDS = ("capsule_image", "capsule_imagev5", "header_image")

# Steam's CDN sometimes answers with a tiny/empty 200 stub instead of a 404;
# anything smaller than this isn't a real capsule.
_MIN_IMAGE_BYTES = 1024

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger(__name__)

s3 = boto3.client("s3")


class CapsuleImageNotFound(Exception):
    """Raised when an app has no usable capsule art (never will — don't retry)."""


def _fetch(url):
    with request.urlopen(request.Request(url, headers=_HEADERS)) as response:
        return response.read()


def get_capsule_image_from_steam_store(steam_game_id):
    params = parse.urlencode({"appids": steam_game_id})
    url = f"{STEAM_STORE_BASE_URL}/api/appdetails?{params}"

    entry = json.loads(_fetch(url)).get(str(steam_game_id)) or {}
    if not entry.get("success"):
        raise CapsuleImageNotFound(f"appdetails success=false for {steam_game_id}")

    details = entry.get("data") or {}
    for field in _IMAGE_FIELDS:
        image_url = details.get(field)
        if not image_url:
            continue
        image = _fetch(image_url)
        if len(image) >= _MIN_IMAGE_BYTES:
            return image
        logger.warning(
            "Field %s for %s returned a degenerate %d-byte image; trying next field",
            field, steam_game_id, len(image),
        )

    raise CapsuleImageNotFound(f"no usable capsule art for {steam_game_id}")


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

            try:
                capsule_image = get_capsule_image_from_steam_store(steam_game_id)
            except CapsuleImageNotFound as e:
                logger.warning("No capsule art for game %s (%s), skipping", steam_game_id, e)
                continue

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
