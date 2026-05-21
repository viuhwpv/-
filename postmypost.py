import os
import random
import time
import requests
from datetime import datetime, timedelta
from dateutil import tz

# Библиотеки Google Drive
from googleapiclient.discovery import build
from google.oauth2 import service_account
from googleapiclient.http import MediaIoBaseDownload

# ======================
# CONFIG
# ======================
POSTMYPOST_TOKEN = "aJs_pt-Xy_UKMO6CP7lBr_-FL_zN_sbw"
PROJECT_ID = 316933
INSTAGRAM_ACCOUNT_ID = 2047408

GOOGLE_FOLDER_ID = "1rTGoWC_fRS8QLiyQO0w5zkCnME_vvrmV"
ARCHIVE_FOLDER_NAME = "Published"

TIME_SLOTS = ["10:00", "19:00"]
TIMEZONE = "Europe/Paris"

SCOPES = ['https://www.googleapis.com/auth/drive']
CREDS_FILE = 'credentials.json'


# ======================
# GOOGLE DRIVE
# ======================
def get_drive_service():
    creds = service_account.Credentials.from_service_account_file(
        CREDS_FILE, scopes=SCOPES
    )
    return build('drive', 'v3', credentials=creds)


def get_or_create_archive_folder(service):
    query = f"'{GOOGLE_FOLDER_ID}' in parents and mimeType = 'application/vnd.google-apps.folder' and name = '{ARCHIVE_FOLDER_NAME}' and trashed=false"
    results = service.files().list(q=query, fields="files(id)").execute()
    files = results.get('files', [])

    if files:
        return files[0]['id']
    else:
        print(f"Папка '{ARCHIVE_FOLDER_NAME}' создается...")
        metadata = {
            'name': ARCHIVE_FOLDER_NAME,
            'mimeType': 'application/vnd.google-apps.folder',
            'parents': [GOOGLE_FOLDER_ID]
        }
        folder = service.files().create(body=metadata, fields='id').execute()
        return folder.get('id')


def move_to_archive(service, file_id, archive_id):
    file = service.files().get(fileId=file_id, fields='parents').execute()
    if 'parents' in file:
        previous_parents = ",".join(file.get('parents'))
        service.files().update(
            fileId=file_id,
            addParents=archive_id,
            removeParents=previous_parents,
            fields='id, parents'
        ).execute()
        print(f"📁 Файл перемещен в архив.")
    else:
        print("⚠️ Не удалось переместить файл (нет родителя).")


def get_drive_images(service):
    results = service.files().list(
        q=f"'{GOOGLE_FOLDER_ID}' in parents and mimeType contains 'image/' and trashed=false",
        fields="files(id, name)"
    ).execute()

    files = results.get('files', [])
    downloaded_items = []

    for f in files:
        file_name = f['name']
        file_id = f['id']

        # Чистим старые файлы перед скачиванием
        if os.path.exists(file_name):
            try:
                os.remove(file_name)
            except:
                pass

        print(f"Скачиваем {file_name}...")
        request = service.files().get_media(fileId=file_id)
        with open(file_name, 'wb') as fh:
            downloader = MediaIoBaseDownload(fh, request)
            done = False
            while not done:
                _, done = downloader.next_chunk()

        if os.path.getsize(file_name) > 0:
            downloaded_items.append({'name': file_name, 'id': file_id})
        else:
            print(f"⚠️ Файл {file_name} пустой. Пропускаем.")

    return downloaded_items


# ======================
# POSTMYPOST API
# ======================
def get_mime_type(filename):
    ext = os.path.splitext(filename)[1].lower()
    return {
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.heic': 'image/heic',
        '.heif': 'image/heif'
    }.get(ext, 'image/jpeg')


def generate_safe_name(filename):
    """Безопасное имя файла (латиница + цифры)"""
    ext = os.path.splitext(filename)[1].lower()
    return f"img_{int(time.time())}_{random.randint(10, 99)}{ext}"


# --- 1. INITIALIZE ---
def init_upload(local_path, target_name):
    size = os.path.getsize(local_path)
    mime = get_mime_type(local_path)

    url = "https://api.postmypost.io/v4.1/upload/init"

    payload = {
        "project_id": PROJECT_ID,
        "name": target_name,
        "size": size,
        "type": mime
    }

    r = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {POSTMYPOST_TOKEN}",
            "Accept": "application/json"
        },
        json=payload
    )
    if r.status_code != 200:
        raise RuntimeError(f"Ошибка Init: {r.status_code}, {r.text}")
    return r.json()


# --- 2. UPLOAD TO S3 ---
def upload_to_s3(upload_data, local_path, target_name):
    print(f"Загрузка {local_path} в облако...")
    mime = get_mime_type(local_path)

    with open(local_path, "rb") as f:
        file_content = f.read()

    if "fields" in upload_data and "action" in upload_data:
        files = {"file": (target_name, file_content, mime)}
        data = {field["key"]: field["value"] for field in upload_data["fields"]}
        response = requests.post(upload_data["action"], data=data, files=files)

        if response.status_code not in [200, 204]:
            raise RuntimeError(f"Ошибка S3: {response.status_code} {response.text}")

    elif "url" in upload_data:
        headers = {'Content-Type': mime}
        response = requests.put(upload_data["url"], data=file_content, headers=headers)
        if response.status_code not in [200, 201]:
            raise RuntimeError(f"Ошибка URL: {response.text}")


# --- 3. COMPLETE ---
def complete_upload(file_id):
    url = "https://api.postmypost.io/v4.1/upload/complete"
    try:
        file_id = int(file_id)
    except:
        pass

    params = {
        "project_id": PROJECT_ID,
        "id": file_id
    }

    r = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {POSTMYPOST_TOKEN}",
            "Accept": "application/json"
        },
        params=params
    )

    if r.status_code == 200:
        return True
    else:
        print(f"⚠️ Ошибка Complete: {r.status_code}, {r.text}")
        return False


# --- 4. STATUS ---
def check_upload_status(file_id):
    url = "https://api.postmypost.io/v4.1/upload/status"
    try:
        file_id = int(file_id)
    except:
        pass

    params = {
        "project_id": PROJECT_ID,
        "id": file_id
    }

    for attempt in range(30):
        try:
            r = requests.get(
                url,
                headers={
                    "Authorization": f"Bearer {POSTMYPOST_TOKEN}",
                    "Accept": "application/json"
                },
                params=params
            )

            if r.status_code == 200:
                data = r.json()
                status = data.get("status")

                if status == 1:
                    print("✅ Файл готов (Status 1)!")
                    # !!! ВАЖНАЯ ПАУЗА: даем серверу время "привязать" файл !!!
                    print("⏳ Ждем 5 секунд для синхронизации...")
                    time.sleep(5)
                    return True
                elif status == 2:
                    print("❌ Ошибка обработки файла на сервере (Status 2).")
                    return False
                elif status in [3, 4, 5]:
                    pass
                else:
                    print(f"❓ Статус: {status}")
            else:
                print(f"⚠️ Ошибка проверки статуса: {r.status_code} | {r.text}")

        except Exception as e:
            print(f"⚠️ Ошибка сети: {e}")

        time.sleep(2)

    print("⏰ Тайм-аут ожидания обработки.")
    return False


# --- 5. CREATE POST (Исправлено на ЧЕРНОВИК) ---
def create_post(file_id, publish_at, text="New Post"):
    url = "https://api.postmypost.io/v4.1/publications"
    try:
        file_id = int(file_id)
    except:
        pass

    payload = {
        "project_id": PROJECT_ID,
        "account_ids": [INSTAGRAM_ACCOUNT_ID],

        # Попробуем передать ID и как число, и в details
        "media_ids": [file_id],

        "post_at": publish_at.isoformat(),

        # !!! ВАЖНО: Ставим статус 1 (ЧЕРНОВИК), чтобы проверить картинку !!!
        "publication_status": 1,

        "type": "post",
        "details": [
            {
                "account_id": INSTAGRAM_ACCOUNT_ID,
                "publication_type": 1,
                "content": text,
                "media_ids": [file_id]
            }
        ]
    }

    r = requests.post(
        url,
        headers={"Authorization": f"Bearer {POSTMYPOST_TOKEN}", "Content-Type": "application/json"},
        json=payload
    )

    if r.status_code == 200:
        print(f"✅ УСПЕХ! Пост создан в ЧЕРНОВИКАХ на {publish_at}")
        # Выводим ID поста для проверки
        try:
            print(f"🆔 ID поста: {r.json().get('id', 'Неизвестен')}")
        except:
            pass
        return True
    elif r.status_code == 422:
        print(f"❌ Ошибка создания (422): {r.text}")
    else:
        print(f"❌ Ошибка создания: {r.status_code}, {r.text}")
    return False


# ======================
# SCHEDULING
# ======================
def generate_times(count):
    zone = tz.gettz(TIMEZONE)
    now = datetime.now(zone)
    times = []
    day = now.date()
    slot_index = 0
    attempts = 0
    max_attempts = count * 20

    while len(times) < count and attempts < max_attempts:
        attempts += 1
        time_str = TIME_SLOTS[slot_index % len(TIME_SLOTS)]
        hour, minute = map(int, time_str.split(":"))

        offset = random.randint(-15, 15)
        dt = datetime.combine(day, datetime.min.time()).replace(hour=hour, minute=minute, tzinfo=zone)
        dt += timedelta(minutes=offset)

        if dt > now:
            times.append(dt)

        slot_index += 1
        if slot_index % len(TIME_SLOTS) == 0:
            day += timedelta(days=1)
    return times


# ======================
# MAIN
# ======================
def main():
    try:
        drive_service = get_drive_service()
        archive_id = get_or_create_archive_folder(drive_service)
        images_info = get_drive_images(drive_service)

        if not images_info:
            print("Нет новых изображений.")
            return

        print(f"Всего изображений: {len(images_info)}")
        publish_times = generate_times(len(images_info))

        for item, publish_at in zip(images_info, publish_times):
            img_path = item['name']
            drive_file_id = item['id']

            safe_server_name = generate_safe_name(img_path)

            print(f"\n--- Обработка {img_path} ---")
            try:
                # 1. Init
                upload_data = init_upload(img_path, safe_server_name)
                pmp_file_id = upload_data.get("id")

                if not pmp_file_id:
                    print("❌ Ошибка: не получен ID файла.")
                    continue

                # 2. Upload
                upload_to_s3(upload_data, img_path, safe_server_name)

                # 3. Complete
                if not complete_upload(pmp_file_id):
                    continue

                # 4. Status Check
                if check_upload_status(pmp_file_id):
                    # 5. Create Post (Draft)
                    caption = f"New Photo {safe_server_name}"  # Временный текст
                    if create_post(pmp_file_id, publish_at, text=caption):
                        move_to_archive(drive_service, drive_file_id, archive_id)
                        if os.path.exists(img_path):
                            os.remove(img_path)
                            print("🗑 Локальный файл удален.")
                else:
                    print("❌ Файл не готов. Пропуск.")

            except Exception as e:
                print(f"❌ Ошибка в цикле: {e}")

    except Exception as e:
        print(f"Критическая ошибка: {e}")


if __name__ == "__main__":
    main()