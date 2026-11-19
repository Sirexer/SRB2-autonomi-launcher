# Translations

**English** | [Русский](translations.ru.md)

English is built into the launcher; other languages are JSON files in the
`lang` folder next to it (`lang/ru.json`, `lang/de.json`...; the `lang/` folder
in the repository). Russian, Ukrainian (`ua`), German, Spanish and Portuguese
(Brazilian, `pt`) are there now.

## Adding a language

1. Copy `ru.json` to `lang/<code>.json` (`fr.json`, `pl.json`...).
2. Set `"_language"` to the language's own name (`"Français"`) and `"_flag"`
   to the country code of its flag (`fr`, `br`, `es`...; the flags are in
   `assets/flags`).
3. Translate the values. The keys are the English text — do not change them.
   Keep the placeholders in braces (`{n}`, `{name}`, `{game}`...) as they are;
   the word order around them is up to you.

```json
{
  "_language": "Français",
  "_flag": "fr",
  "Settings": "Paramètres",
  "Added {n} file(s) to launch queue!": "{n} fichier(s) ajouté(s) à la file de lancement !"
}
```

- The language shows up in Settings → General and in the first-run wizard
  (with its flag). If the system language matches the file's code, it is
  chosen by itself on the first start (Ukrainian: system `uk` → file
  `ua.json`).
- Untranslated strings are shown in English, so a file can be translated bit
  by bit.
- Leave SRB2 color codes in strings (`^2`, `\x82`) as they are.

Send the file to the repository (a pull request) so the language makes it
into the next release.
