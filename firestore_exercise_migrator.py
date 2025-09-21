# Copy entire 'exercises' collection from OLD → NEW, preserving IDs.
# Runs locally with your gcloud Application Default Credentials.
# Run with: py firestore_exercises_copy.py

from google.cloud import firestore
import google.auth

OLD_PROJECT = "re-app-richardversion"
NEW_PROJECT = "goodlift-us-storage"

OVERWRITE = True   # True=overwrite existing docs in new project
DRY_RUN   = False  # True=just print, don’t write anything

# Use your gcloud login (ADC = Application Default Credentials)
adc_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])

old_db = firestore.Client(project=OLD_PROJECT, credentials=adc_creds)
new_db = firestore.Client(project=NEW_PROJECT, credentials=adc_creds)

src = old_db.collection("exercises")
dst = new_db.collection("exercises")

count = 0
for snap in src.stream():
    doc_id = snap.id
    data = snap.to_dict()

    print(f"{'WOULD COPY' if DRY_RUN else 'Copying'}: {doc_id}")

    if not DRY_RUN:
        ref = dst.document(doc_id)  # preserve the SAME ID
        ref.set(data, merge=not OVERWRITE)

    count += 1

print(("✅ DRY-RUN complete." if DRY_RUN else "✅ Done.") +
      f" Processed {count} docs from {OLD_PROJECT} → {NEW_PROJECT}.")
