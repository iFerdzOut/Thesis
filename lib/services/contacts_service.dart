import 'package:flutter_contacts/flutter_contacts.dart';

class ContactsServiceHelper {
  Future<List<Contact>> getContacts() async {
    final hasPermission =
        await FlutterContacts.requestPermission(readonly: true);

    if (!hasPermission) {
      return [];
    }

    return FlutterContacts.getContacts(
      withProperties: true,
      withAccounts: true,
      deduplicateProperties: true,
    );
  }
}
