# Copy 'weights' subcollections from OLD → NEW, preserving doc IDs.
# Uses your gcloud login (no service accounts). Start with DRY_RUN = True.
# Run: py .\firestore_weights_migrator.py

from google.cloud import firestore
import google.auth

# ----- PROJECTS -----
OLD_PROJECT = "re-app-richardversion"
NEW_PROJECT = "goodlift-us-storage"

# ----- USER MAPPINGS (old_uid, new_uid) -----
USER_MAPPINGS = [
      #("Rp6gFj16KMgsmOtC9tZGlUDCNRr1", "0QBzny0y38TFiHFg5kZxUvYPpLr1"), #Courtney
       #   ("sOLNje2sDxaOtVY80oz4ImkImWO2", "jhIB7Yi1whYwPvBSmK27KltJGn23"), #Richard17
        #  ("B3dWiljf4ISavFufZ0xN6o9LsD93","wuiMe7phxYQh0MM39bfnhgv20yS2"),  #cjlor
       #   ("AYNFPa59x8SHRq1fysjreGEEmpB2", "tlmT17Jlgfe63OYfk8P2IPAs4072"), #Aja
       #   ("cGH3mi8gFKRQN31xMK7GyPygdSH2", "x1jI30wK4qdQZK4JkE3L21U8Xzu1"), #Steven
      #    ("zm4ZRN6TY8aEDPLj4CqMv8q9Pw83", "Wwwi8K29qCSq477jikx8jvs44Ag2"),  #Meghan
       #   ("HaQMrM15ckSjB6qWCcmDFt6FHDx1", "Ko1E2aZz4Ee7OiWizq4KvAoaXBN2"), #Shawn
          ("Mxj2NXankQdVv4Xrj2sZzBBm4W92", "yoVAqScwLMQLAgNHh8v9IK49fBw2") #Richard Razors
]

# ----- BEHAVIOR -----
DRY_RUN = False          # True = print only
MODE    = "skip"        # "skip" | "merge" | "overwrite"

# Optional: if your weight docs contain a numeric field (e.g. "kg") and timestamps,
# you can add filtering later. For now we copy ALL docs.

# ----- AUTH (uses 'gcloud auth application-default login') -----
adc_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
old_db = firestore.Client(project=OLD_PROJECT, credentials=adc_creds)
new_db = firestore.Client(project=NEW_PROJECT, credentials=adc_creds)

def _write(dst_ref, data):
    if MODE == "overwrite":
        dst_ref.set(data, merge=False)
    elif MODE == "merge":
        dst_ref.set(data, merge=True)
    elif MODE == "skip":
        if not dst_ref.get().exists:
            dst_ref.set(data, merge=False)

def copy_weights_for_user(old_uid: str, new_uid: str) -> int:
    """Copy /users/{old}/weights/* → /users/{new}/weights/* (all docs)."""
    src = old_db.collection("users").document(old_uid).collection("weights")
    dst = new_db.collection("users").document(new_uid).collection("weights")

    moved = 0
    for snap in src.stream():
        doc_id = snap.id         # preserves your existing IDs (dates/auto IDs)
        data   = snap.to_dict()

        # Decide action label for logging
        action = "COPY"
        if MODE == "skip":
            if not DRY_RUN and dst.document(doc_id).get().exists:
                action = "SKIP"
            else:
                action = "COPY"
        elif MODE == "merge":
            action = "MERGE"
        elif MODE == "overwrite":
            action = "OVERWRITE"

        print(f"{'WOULD ' if DRY_RUN else ''}{action}: users/{new_uid}/weights/{doc_id}")

        if not DRY_RUN:
            _write(dst.document(doc_id), data)

        moved += 1

    return moved

def main():
    total = 0
    for old_uid, new_uid in USER_MAPPINGS:
        print(f"\n=== Migrating weights: {old_uid} → {new_uid} ===")
        moved = copy_weights_for_user(old_uid, new_uid)
        print(f"Processed {moved} weight docs for {new_uid}.")
        total += moved

    print(("\n✅ DRY-RUN complete." if DRY_RUN else "\n✅ Done.")
          + f" Processed {total} weight docs across {len(USER_MAPPINGS)} user(s).")

if __name__ == "__main__":
    main()
