import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_debug.dart';
import '../SavedWorkoutsScreen.dart';
import 'user_context.dart';
import 'coach_home_screen.dart';
import 'main.dart';
import 'planned_blocks_screen.dart';
import 'package:provider/provider.dart';
import 'block_planner.dart';
import 'bb3_week_planner.dart';
import 'templates.dart';
import 'exercises.dart';
import 'body_weight_tracker.dart';
import 'user_settings.dart';
import 'create_new_account_screen.dart';



class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});


  @override
  Widget build(BuildContext context) {
    final userEmail = FirebaseAuth.instance.currentUser?.email ?? 'User';

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // 🧠 Custom compact header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Colors.blueGrey,
              border: Border(
                bottom: BorderSide(color: Colors.white70, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 14), // adjust this value to move it lower
                  child: const CircleAvatar(
                    radius: 28,
                    backgroundImage: AssetImage('assets/avatar.png'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Welcome", style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(
                        userEmail,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 🗂️ Planning section
          const DrawerSectionHeader(title: "Planning"),
          _drawerTile(context, Icons.view_module, 'Planned Blocks', () {
            final userContext = UserContext.of(context, listen: false);

            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const PlannedBlocksScreen(),
                ),
              ),
            );
          }),

          _drawerTile(context, Icons.extension, 'Block Planner', () {
            final userContext = UserContext.of(context, listen: false);

            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const Block_Planner(),
                ),
                settings: RouteSettings(
                  arguments: {'newBlock': true}, // 👈 preserve your arguments
                ),
              ),
            );
          }),

          _drawerTile(context, Icons.calendar_view_week, 'BB3 Week Planner', () {
            final userContext = UserContext.of(context, listen: false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const BB3WeekPlanner(),
                ),
              ),
            );
          }),

          _drawerTile(context, Icons.tune, 'Training Preferences', () async {
            final userContext = UserContext.of(context, listen: false);
            final email = FirebaseAuth.instance.currentUser?.email ?? '';
            final db = FirebaseFirestore.instance;
            String? sex;
            String? dob;
            try {
              final snap = await db.collection('users').doc(userContext.currentUid).get();
              sex = snap.data()?['sex']?.toString();
              dob = snap.data()?['dob']?.toString();
            } catch (_) {}
            if (!context.mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: OnboardingPageTwo(
                    email: email,
                    password: 'edit-mode',
                    sex: sex,
                    username: null,
                    fullName: null,
                    dob: dob,
                  ),
                ),
                settings: const RouteSettings(
                  arguments: {'entryFrom': 'drawer'},
                ),
              ),
            );
          }),

          _drawerTile(context, Icons.view_list, 'Workout Planner', () {
            final userContext = UserContext.of(context, listen: false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const TemplatesScreen(),
                ),
              ),
            );
          }),


          // 📊 Tracking section
          _drawerTile(context, Icons.fitness_center, 'Exercises', () {
            final userContext = UserContext.of(context, listen: false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const ExercisesScreen(),
                ),
              ),
            );
          }),

          _drawerTile(context, Icons.monitor_weight, 'Weigh In', () {
            final userContext = UserContext.of(context, listen: false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const BodyWeightTracker(),
                ),
              ),
            );
          }),


          // 🕓 History section
          _drawerTile(context, Icons.bookmark, 'Saved Workouts', () {
            final userContext = UserContext.of(context, listen: false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const SavedWorkoutsScreen(),
                ),
              ),
            );
          }),


          // ⚙️ Utilities section
          const DrawerSectionHeader(title: "Utilities"),
          _drawerTile(context, Icons.admin_panel_settings_outlined, 'Settings', () {
            final userContext = context.read<UserContext>();
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider<UserContext>.value(
                  value: userContext,
                  child: const UserSettingsScreen(),
                ),
              ),
            );
          }),

          _drawerTile(context, Icons.logout, 'Logout', () async {
            debugPrint('[AUTHLOGOUT] drawer logout');
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('goodlift_explicit_logout', true);
            await writeAuthBreadcrumb('AUTHLOGOUT drawer uid=${FirebaseAuth.instance.currentUser?.uid}');
            await FirebaseAuth.instance.signOut();
            Navigator.pushReplacementNamed(context, '/login');
          }),

          // // ⚙️ Utilities section
          // const DrawerSectionHeader(title: "Testing"),
          // _drawerTile(context, Icons.adb, 'BB2 Test', () {
          //   Navigator.pushNamed(context, '/BB2');
          // }),

          const CustomDivider(),
        ],
      ),
    );
  }

  Widget _drawerTile(BuildContext context, IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.blueGrey),
      title: Text(title),
      onTap: onTap,
    );
  }
}

// 🔸 Reusable header for section titles
class DrawerSectionHeader extends StatelessWidget {
  final String title;

  const DrawerSectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[100],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
      ),
    );
  }
}

// 🔹 Optional divider between major sections
class CustomDivider extends StatelessWidget {
  const CustomDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      color: Colors.grey.shade400,
      thickness: 0.8,
      indent: 16,
      endIndent: 16,
    );
  }
}
