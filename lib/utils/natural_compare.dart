/// "Естественное" сравнение строк для сортировки по алфавиту:
/// без учёта регистра, а числа сравниваются как числа
/// ("Mod 2" < "Mod 10", "v1.9" < "v1.10").
int naturalCompare(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0;
  var j = 0;

  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i);
    final cy = y.codeUnitAt(j);

    if (_isDigit(cx) && _isDigit(cy)) {
      var xEnd = i;
      while (xEnd < x.length && _isDigit(x.codeUnitAt(xEnd))) {
        xEnd++;
      }
      var yEnd = j;
      while (yEnd < y.length && _isDigit(y.codeUnitAt(yEnd))) {
        yEnd++;
      }
      // Пропускаем ведущие нули: "007" == "7".
      var xStart = i;
      while (xStart < xEnd - 1 && x.codeUnitAt(xStart) == 0x30) {
        xStart++;
      }
      var yStart = j;
      while (yStart < yEnd - 1 && y.codeUnitAt(yStart) == 0x30) {
        yStart++;
      }
      // Более длинное число больше; при равной длине — посимвольно.
      final lengthDiff = (xEnd - xStart) - (yEnd - yStart);
      if (lengthDiff != 0) return lengthDiff;
      final digits = x.substring(xStart, xEnd).compareTo(y.substring(yStart, yEnd));
      if (digits != 0) return digits;
      i = xEnd;
      j = yEnd;
    } else {
      if (cx != cy) return cx - cy;
      i++;
      j++;
    }
  }

  final rest = (x.length - i) - (y.length - j);
  if (rest != 0) return rest;
  // Полностью равны без учёта регистра — фиксированный порядок по исходным строкам.
  return a.compareTo(b);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
