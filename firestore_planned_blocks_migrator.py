# Recursively copy legacy /planned_blocks/{uid}/blocks/{blockId} from OLD to
# canonical /users/{uid}/planned_blocks/{blockId} in NEW:
# - preserves every block document ID and field
# - copies ALL nested subcollections (weeks/days, block_data, and future ones)
# Uses your gcloud login. Start with DRY_RUN = True.
# Run: py firestore_planned_blocks_migrator.py

from google.cloud import firestore
import google.auth

# ---- PROJECTS ----
OLD_PROJECT = "re-app-richardversion"
NEW_PROJECT = "goodlift-us-storage"

# ---- USER MAPPINGS (old_uid, new_uid) ----
USER_MAPPINGS = [
   # ("A6qwQDxzHKQmQMSkwEgkZ9Etxzw1", "HAMSqppwkVg87yzkc4hu9ag9Ozn1"), #Clifford
     #("Rp6gFj16KMgsmOtC9tZGlUDCNRr1", "0QBzny0y38TFiHFg5kZxUvYPpLr1"), #Courtney
      ("sOLNje2sDxaOtVY80oz4ImkImWO2", "jhIB7Yi1whYwPvBSmK27KltJGn23"), #Richard17
      ("B3dWiljf4ISavFufZ0xN6o9LsD93","wuiMe7phxYQh0MM39bfnhgv20yS2"),  #cjlor
      ("AYNFPa59x8SHRq1fysjreGEEmpB2", "tlmT17Jlgfe63OYfk8P2IPAs4072"), #Aja
      ("cGH3mi8gFKRQN31xMK7GyPygdSH2", "x1jI30wK4qdQZK4JkE3L21U8Xzu1"), #Steven
      ("zm4ZRN6TY8aEDPLj4CqMv8q9Pw83", "Wwwi8K29qCSq477jikx8jvs44Ag2"),  #Meghan
      ("HaQMrM15ckSjB6qWCcmDFt6FHDx1", "Ko1E2aZz4Ee7OiWizq4KvAoaXBN2"), #Shawn
      ("SMTEVGPH1MXgOgbcBbJFU1HjU8G3", "LGxzlyBNh5f1zclM1F0l6tl6Py82") #Adam
]

# ---- BEHAVIOR ----
DRY_RUN   = True              # print only; no writes
MODE      = "skip"           # "skip" | "merge" | "overwrite"

# ---- AUTH ----
adc_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
old_db = firestore.Client(project=OLD_PROJECT, credentials=adc_creds)
new_db = firestore.Client(project=NEW_PROJECT, credentials=adc_creds)

def _upsert(dst_ref, data):
    if MODE == "overwrite":
        dst_ref.set(data, merge=False)
    elif MODE == "merge":
        dst_ref.set(data, merge=True)
    elif MODE == "skip":
        if not dst_ref.get().exists:
            dst_ref.set(data, merge=False)

def _copy_doc_recursive(src_doc_ref: firestore.DocumentReference,
                        dst_doc_ref: firestore.DocumentReference,
                        path_hint: str) -> int:
    """Copy this doc's fields, then recurse into all of its subcollections."""
    moved = 0

    # Copy doc fields (if exists)
    src_snap = src_doc_ref.get()
    if src_snap.exists:
        action = "OVERWRITE" if MODE == "overwrite" else "MERGE" if MODE == "merge" else "UPSERT"
        print(f"{'WOULD ' if DRY_RUN else ''}{action}: {path_hint}")
        if not DRY_RUN:
            _upsert(dst_doc_ref, src_snap.to_dict())
        moved += 1
    # Recurse into every subcollection under this doc
    for subcol in src_doc_ref.collections():
        for child_snap in subcol.stream():
            child_src = src_doc_ref.collection(subcol.id).document(child_snap.id)
            child_dst = dst_doc_ref.collection(subcol.id).document(child_snap.id)
            child_path = f"{path_hint}/{subcol.id}/{child_snap.id}"
            moved += _copy_doc_recursive(child_src, child_dst, child_path)

    return moved

def copy_planned_blocks_for_user(old_uid: str, new_uid: str) -> int:
    src_user_doc = old_db.collection("planned_blocks").document(old_uid)
    dst_blocks = (new_db.collection("users").document(new_uid)
                  .collection("planned_blocks"))
    moved = 0
    for src_block in src_user_doc.collection("blocks").list_documents():
        dst_block = dst_blocks.document(src_block.id)
        moved += _copy_doc_recursive(
            src_block,
            dst_block,
            f"users/{new_uid}/planned_blocks/{src_block.id}",
        )
    return moved

def main():
    total = 0
    for old_uid, new_uid in USER_MAPPINGS:
        print(f"\n=== Migrating planned_blocks recursively: {old_uid} → {new_uid} ===")
        moved = copy_planned_blocks_for_user(old_uid, new_uid)
        print(f"Processed {moved} doc writes (including nested) for {new_uid}.")
        total += moved

    print(("\n✅ DRY-RUN complete." if DRY_RUN else "\n✅ Done.")
          + f" Total docs processed (incl. nested): {total} for {len(USER_MAPPINGS)} user(s).")

if __name__ == "__main__":
    main()
