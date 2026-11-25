import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelai_harness/data/models/nai_catalog.dart';
import 'package:novelai_harness/data/models/nai_generation_params.dart';
import 'package:novelai_harness/l10n/app_localizations.dart';
import 'package:novelai_harness/ui/features/studio/view_models/studio_view_model.dart';
import 'package:novelai_harness/ui/features/studio/widgets/precise_reference_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('V5 precise reference exposes four types and outfit toggle', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'novelai_enable_tag_dictionary_auto_update': false,
      'novelai_enable_image_persistence': false,
    });
    final dir = Directory.systemTemp.createTempSync('precise_ui_');
    final viewModel = StudioViewModel(sessionLogBaseDir: dir.path);
    addTearDown(() async {
      viewModel.dispose();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    viewModel.updateParams(viewModel.params.copyWith(model: NaiModel.v5Full));
    viewModel.addPreciseReference(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zb9sAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: PreciseReferenceSection(viewModel: viewModel),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(DropdownButton<NaiPreciseRefType>), findsOneWidget);
    expect(find.text('Prefer same outfit'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<NaiPreciseRefType>));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Character'), findsWidgets);
    expect(find.text('Style'), findsWidgets);
    expect(find.text('Character + style'), findsWidgets);
    expect(find.text('Outfit'), findsWidgets);
  });
}
