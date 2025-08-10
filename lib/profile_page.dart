import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'periodization_model_utils.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _picker = ImagePicker();
  File? _localProfileImage;           // <-- use this one
  String? photoURL;

  // Bio + lifts
  final TextEditingController _bioController = TextEditingController();
  double squat = 0, bench = 0, deadlift = 0, chinUp = 0, unilateralPress = 0;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
    _loadPhotoURL();
  }

  Future<void> _loadProfileData() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (doc.exists) {
      final data = doc.data() ?? {};
      _bioController.text = data['bio'] ?? '';
      squat = (data['bestSquat'] ?? 0).toDouble();
      bench = (data['bestBench'] ?? 0).toDouble();
      deadlift = (data['bestDeadlift'] ?? 0).toDouble();
      chinUp = (data['bestChinUp'] ?? 0).toDouble();
      unilateralPress = (data['bestUnilateralPress'] ?? 0).toDouble();
    }
    setState(() => isLoading = false);
  }

  Future<void> _saveProfileData() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;

    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'bio': _bioController.text,
      'bestSquat': squat,
      'bestBench': bench,
      'bestDeadlift': deadlift,
      'bestChinUp': chinUp,
      'bestUnilateralPress': unilateralPress,
    }, SetOptions(merge: true));
  }

  Future<void> _loadPhotoURL() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (snap.exists) {
        setState(() {
          photoURL = snap.data()?['photoURL'] as String?;
        });
      }
    } catch (e) {
      debugPrint('❌ Failed to load photoURL: $e');
    }
  }



  Future<void> _pickAndUploadProfileImage() async {
    debugPrint("📸 Picker tapped (ProfilePage)");
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) {
      debugPrint('❌ No image selected');
      return;
    }

    setState(() => _localProfileImage = File(picked.path));

    final uid = UserContext.of(context, listen: false).currentUid;
    final file = File(picked.path);
    final path = 'users/$uid/profile.jpg';

    try {
      // Upload
      final task = await FirebaseStorage.instance.ref(path).putFile(file);
      final url = await task.ref.getDownloadURL();

      // Save to Firestore
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'photoURL': url,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo updated')),
      );
      debugPrint('✅ Uploaded profile to $path\nURL: $url');
    } catch (e) {
      debugPrint('❌ Upload failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to upload profile photo')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final userEmail = FirebaseAuth.instance.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blueGrey,
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    userEmail,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      overflow: TextOverflow.ellipsis,
                    ),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: Colors.grey.shade300,
                  backgroundImage: _localProfileImage != null
                      ? FileImage(_localProfileImage!)
                      : (photoURL != null && photoURL!.isNotEmpty)
                      ? NetworkImage(photoURL!)
                      : null,
                  child: (_localProfileImage == null && (photoURL == null || photoURL!.isEmpty))
                      ? const Icon(Icons.person, size: 44)
                      : null,
                ),

                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _pickAndUploadProfileImage,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Change photo'),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Bio Section
            const Text('About Me',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _bioController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Write a short bio about yourself...',
                filled: true,
                fillColor: Colors.blueGrey.shade50,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 20),

            // Best Lifts Section
            const Text('Best Lifts',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildLiftRow('Squat', squat, (v) => squat = v),
            _buildLiftRow('Bench Press', bench, (v) => bench = v),
            _buildLiftRow('Deadlift', deadlift, (v) => deadlift = v),
            _buildLiftRow('Chin Up', chinUp, (v) => chinUp = v),
            _buildLiftRow('Unilateral DB Press', unilateralPress,
                    (v) => unilateralPress = v),
            const SizedBox(height: 20),

            // Stats
            const Text('Stats',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Goodlift Points: (pending calc)',
                style: Theme.of(context).textTheme.bodyLarge),
            Text('RE Points: (pending calc)',
                style: Theme.of(context).textTheme.bodyLarge),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveProfileData,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
              child: const Text('Save Profile'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiftRow(String label, double value, Function(double) onChanged) {
    final controller = TextEditingController(text: value.toString());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          SizedBox(
            width: 80,
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (val) => onChanged(double.tryParse(val) ?? 0),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.blueGrey.shade50,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
