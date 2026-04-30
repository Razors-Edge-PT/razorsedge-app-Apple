const admin = require("firebase-admin");

const serviceAccount = require("./serviceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const uid = "Wwwi8K29qCSq477jikx8jvs44Ag2";
const email = "meghanlawson1992@gmail.com";
const temporaryPassword = "MegMog";

async function run() {
  console.log("About to update existing Firebase Auth user:");
  console.log(`UID: ${uid}`);
  console.log(`Email: ${email}`);
  console.log("This script will NOT create a new user.");

  const updatedUser = await admin.auth().updateUser(uid, {
    email,
    password: temporaryPassword,
    emailVerified: true,
  });

  console.log("Done. Email/password login has been added/updated.");
  console.log(`Updated UID: ${updatedUser.uid}`);
  console.log(`Updated email: ${updatedUser.email}`);
  console.log("Meghan can now log in with:");
  console.log(`Email: ${email}`);
  console.log(`Temporary password: ${temporaryPassword}`);
}

run().catch((error) => {
  console.error("Failed to update user:", error);
  process.exit(1);
});
