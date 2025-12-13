import 'package:shared_preferences/shared_preferences.dart';

class DemographicsCache {
  static String _kSex(String uid) => 'demo_sex_$uid';
  static String _kDob(String uid) => 'demo_dob_$uid';

  static Future<void> save({
    required String uid,
    String? sex,
    String? dob,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    print('🧪 [DemoCache SAVE] uid=$uid sex="$sex" dob="$dob"');

    if (sex != null) await prefs.setString(_kSex(uid), sex);
    if (dob != null) await prefs.setString(_kDob(uid), dob);
  }

  static Future<(String? sex, String? dob)> load(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_kSex(uid)), prefs.getString(_kDob(uid)));
  }

  static Future<void> clear(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSex(uid));
    await prefs.remove(_kDob(uid));
  }
}
