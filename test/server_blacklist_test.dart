import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/services/server_blacklist.dart';

void main() {
  test('blacklist: by address (host or host:port) and by word', () async {
    SharedPreferences.setMockInitialValues({});
    final list = ServerBlacklist.instance;
    await list.load();
    await list.addAddress('151.145.49.64', 5029);
    await list.addAddress('10.0.0.1');
    await list.addAddress('2001:db8::1', 5029);
    await list.addWord('  Badword ');
    await list.addWord('badword'); // уже есть

    expect(list.addresses, ['151.145.49.64:5029', '10.0.0.1', '[2001:db8::1]:5029']);
    expect(list.words, ['Badword']);
    expect(list.blocksAddress('151.145.49.64', 5029), isTrue);
    expect(list.blocksAddress('151.145.49.64', 5030), isFalse); // другой сервер на том же адресе
    expect(list.blocksAddress('10.0.0.1', 1), isTrue); // весь адрес
    expect(list.blocksAddress('2001:DB8::1', 5029), isTrue);
    expect(list.wordIn('hype BADWORD moments'), 'Badword');
    expect(list.blocks('1.2.3.4', 5029, 'nice server'), isFalse);

    // Сохраняется.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('servers_blacklist_words'), ['Badword']);
    await list.removeWord('Badword');
    await list.removeAddress('10.0.0.1');
    expect(list.blocks('10.0.0.1', 1, 'hype badword'), isFalse);
  });
}
