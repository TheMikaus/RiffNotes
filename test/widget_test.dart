import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/main.dart';

void main() {
  testWidgets('shows the RiffNotes library starting point', (tester) async {
    await tester.pumpWidget(const RiffNotesApp());

    expect(find.text('RiffNotes'), findsOneWidget);
    expect(find.text('Start by choosing your Band Folder.'), findsOneWidget);
  });
}
