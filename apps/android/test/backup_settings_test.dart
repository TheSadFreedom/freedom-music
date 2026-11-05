import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:freedom_music/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exportArtistPhotoPaths skips manual bool keys', () async {
    SharedPreferences.setMockInitialValues({
      'artist_photo_alpha': '/photos/alpha.jpg',
      'artist_photo_manual_alpha': true,
      'artist_photo_beta': '/photos/beta.jpg',
      'artist_photo_manual_beta': false,
      'scan_on_startup': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);

    expect(
      settings.exportArtistPhotoPaths(),
      {
        'alpha': '/photos/alpha.jpg',
        'beta': '/photos/beta.jpg',
      },
    );
  });

  test('replaceArtistPhotoPaths restores photos as manual', () async {
    SharedPreferences.setMockInitialValues({
      'artist_photo_old': '/old.jpg',
      'artist_photo_manual_old': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);

    await settings.replaceArtistPhotoPaths({
      'new': '/new.jpg',
    });

    expect(settings.exportArtistPhotoPaths(), {'new': '/new.jpg'});
    expect(settings.isArtistPhotoManual('new'), isTrue);
    expect(settings.artistPhotoPath('old'), isNull);
    expect(settings.isArtistPhotoManual('old'), isFalse);
  });

  test('exportSettingsFlags round-trips through import', () async {
    SharedPreferences.setMockInitialValues({
      'scan_on_startup': false,
      'play_on_startup': true,
      'auto_fill_empty_metadata': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);

    final flags = settings.exportSettingsFlags();
    expect(flags['scanOnStartup'], isFalse);
    expect(flags['playOnStartup'], isTrue);
    expect(flags['autoFillEmptyMetadata'], isFalse);

    await settings.importSettingsFlags({
      'scanOnStartup': true,
      'playOnStartup': false,
      'autoFillEmptyMetadata': true,
    });
    expect(settings.scanOnStartup, isTrue);
    expect(settings.playOnStartup, isFalse);
    expect(settings.autoFillEmptyMetadata, isTrue);
  });
}
