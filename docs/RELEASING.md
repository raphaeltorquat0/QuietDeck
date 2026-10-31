# Como publicar uma release

Checklist, nesta ordem:

- [ ] Suba `MARKETING_VERSION` e `CURRENT_PROJECT_VERSION` no `project.yml`, a única fonte da versão
- [ ] `make test` e `make integration`
- [ ] Passe pelo `SMOKE_TEST.md` num Deck real
- [ ] `make release`
- [ ] `scripts/update-cask.sh`
- [ ] Commit e push do `main`
- [ ] Crie a tag e a release com o `.dmg` de `dist/`:
  ```sh
  VERSION=0.1.0
  gh release create "v$VERSION" "dist/QuietDeck-$VERSION.dmg" --title "QuietDeck $VERSION" --notes-file docs/releases/$VERSION.md
  ```
- [ ] Baixe o `.dmg` da release e confira o sha256 com `shasum -a 256`
- [ ] Copie `Casks/quietdeck.rb` para `raphaeltorquat0/homebrew-tap` e faça push
- [ ] `brew install --cask raphaeltorquat0/tap/quietdeck`

O `.dmg` não é reproduzível: recompilar muda o sha256, e é preciso rodar `scripts/update-cask.sh` de novo.

Assinatura: ad-hoc, sem notarização. O cask não remove a quarentena de propósito, como no Quietbar.
