import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../SavedWorkoutsScreen.dart';

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
              color: Colors.cyan,
              border: Border(
                bottom: BorderSide(color: Colors.white70, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 28,
                  backgroundImage: AssetImage('assets/avatar.png'),
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
            Navigator.pushNamed(context, '/planned_blocks');
          }),
          _drawerTile(context, Icons.extension, 'Block Planner', () {
            Navigator.pushNamed(
              context,
              '/block_builder',
              arguments: {'newBlock': true},
            );
          }),
          _drawerTile(context, Icons.schedule, 'Week Planner', () {
            Navigator.pushNamed(context, '/block_builder_2');
          }),
          _drawerTile(context, Icons.auto_graph, 'Workout Planner', () {
            Navigator.pushNamed(context, '/templates');
          }),

          // 📊 Tracking section
          const DrawerSectionHeader(title: "Tracking"),
          _drawerTile(context, Icons.fitness_center, 'Exercises', () {
            Navigator.pushNamed(context, '/exercises');
          }),
          _drawerTile(context, Icons.monitor_weight, 'Weigh In', () {
            Navigator.pushNamed(context, '/body_weight_tracker');
          }),

          // 🕓 History section
          const DrawerSectionHeader(title: "History"),
          _drawerTile(context, Icons.bookmark, 'Saved Workouts', () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const SavedWorkoutsScreen()));
          }),

          // ⚙️ Utilities section
          const DrawerSectionHeader(title: "Utilities"),
          _drawerTile(context, Icons.admin_panel_settings_outlined, 'Settings', () {
            // Placeholder for future user profile/settings
          }),
          _drawerTile(context, Icons.logout, 'Logout', () async {
            await FirebaseAuth.instance.signOut();
            Navigator.pushReplacementNamed(context, '/login');
          }),

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
