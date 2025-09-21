# Copy 'workouts' subcollections from OLD → NEW, preserving doc IDs.
# Uses your gcloud login (no service accounts). Start with DRY_RUN = True.
# Run: py firestore_workouts_migrator.py

from google.cloud import firestore
import google.auth

# ----- PROJECTS -----
OLD_PROJECT = "re-app-richardversion"
NEW_PROJECT = "goodlift-us-storage"

# ----- USER MAPPINGS -----
# Add (old_uid, new_uid) pairs here. Start with just one to test.
USER_MAPPINGS = [
   # ("sOLNje2sDxaOtVY80oz4ImkImWO2", "jhIB7Yi1whYwPvBSmK27KltJGn23"), #Richard17
   # ("B3dWiljf4ISavFufZ0xN6o9LsD93","wuiMe7phxYQh0MM39bfnhgv20yS2"),  #cjlor
   # ("AYNFPa59x8SHRq1fysjreGEEmpB2", "tlmT17Jlgfe63OYfk8P2IPAs4072"), #Aja
   # ("cGH3mi8gFKRQN31xMK7GyPygdSH2", "x1jI30wK4qdQZK4JkE3L21U8Xzu1"), #Steven
   # ("zm4ZRN6TY8aEDPLj4CqMv8q9Pw83", "Wwwi8K29qCSq477jikx8jvs44Ag2")  #Meghan
   # ("HaQMrM15ckSjB6qWCcmDFt6FHDx1", "Ko1E2aZz4Ee7OiWizq4KvAoaXBN2"), #Shawn
   # ("SMTEVGPH1MXgOgbcBbJFU1HjU8G3", "LGxzlyBNh5f1zclM1F0l6tl6Py82") #Adam
    ("Mxj2NXankQdVv4Xrj2sZzBBm4W92", "yoVAqScwLMQLAgNHh8v9IK49fBw2") #RichardRazors
    # ("OLD_UID_3", "NEW_UID_3"),
]

# ----- BEHAVIOR SWITCHES -----
DRY_RUN   = False   # True = print actions only, write nothing
MODE      = "skip" # "overwrite" | "merge" | "skip"

# ----- AUTH (uses your 'gcloud auth application-default login') -----
adc_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
old_db = firestore.Client(project=OLD_PROJECT, credentials=adc_creds)
new_db = firestore.Client(project=NEW_PROJECT, credentials=adc_creds)

def copy_workouts_for_user(old_uid: str, new_uid: str) -> int:
    """Copy /users/{old}/workouts/* → /users/{new}/workouts/*"""
    src = old_db.collection("users").document(old_uid).collection("workouts")
    dst = new_db.collection("users").document(new_uid).collection("workouts")

    moved = 0
    for snap in src.stream():
        doc_id_val = snap.id
        data = snap.to_dict()

        # Decide what to do if destination exists
        action = "COPY"
        if MODE == "skip":
            if not DRY_RUN and dst.document(doc_id_val).get().exists:
                action = "SKIP"
            else:
                action = "COPY"
        elif MODE == "merge":
            action = "MERGE"
        elif MODE == "overwrite":
            action = "OVERWRITE"

        print(f"{'WOULD ' if DRY_RUN else ''}{action}: users/{new_uid}/workouts/{doc_id_val}")

        if not DRY_RUN:
            ref = dst.document(doc_id_val)
            if MODE == "skip":
                if not ref.get().exists:
                    ref.set(data, merge=False)
            elif MODE == "merge":
                ref.set(data, merge=True)
            elif MODE == "overwrite":
                ref.set(data, merge=False)

        moved += 1
    return moved

def main():
    total = 0
    for old_uid, new_uid in USER_MAPPINGS:
        print(f"\n=== Migrating workouts: {old_uid} → {new_uid} ===")
        moved = copy_workouts_for_user(old_uid, new_uid)
        print(f"Processed {moved} workout docs for {new_uid}.")
        total += moved

    print(("\n✅ DRY-RUN complete." if DRY_RUN else "\n✅ Done.")
          + f" Processed {total} workouts across {len(USER_MAPPINGS)} user(s).")


if __name__ == "__main__":
    main()
