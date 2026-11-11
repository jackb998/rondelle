/* Rondelle site: texts in 3 languages. The page ALWAYS opens in English; only ?lang=it|fr changes it. */
const D = {
en: {
 title_home:"Rondelle", title_press:"Rondelle · Press kit",
 meta:"Rondelle is a file converter and toolkit for macOS: drag a file and choose where it comes out, from a wheel you arrange yourself.",
 n_how:"How it works", n_fmt:"Formats", n_priv:"Privacy", n_press:"Press kit", n_sup:"Support", n_home:"← Home",
 tag:"File tools, thoughtfully arranged.",
 lead:"<span class=\"q\">Which site do I use to convert this? Is it safe? Why does it want me to sign up?</span><strong>Skip all that.</strong><span>Drag the file, hold ⇧ Shift, pick the format. It happens on your Mac: nothing gets uploaded.</span>",
 dl:"⬇ Download Rondelle", small:"Free · open source (MIT) · macOS 13 or later · Apple silicon and Intel",
 hint:"Hold <kbd>⇧ Shift</kbd> and the wheel shows the formats for that file: the one you choose comes out of the ring. Move over the wheel to try.",
 g1h:"One gesture, no app to open", g1:"The wheel appears as you drag and shows only what you can do with that file.",
 g2h:"On your Mac", g2:"No file is uploaded. The part that reads your files has no network access.",
 g3h:"Next to the original", g3:"The new file lands in the same folder; the original stays as it is.",
 own_h:"You arrange the wheel", own_l:"Not a list of features to scroll: for each kind of file you keep only what you use, in the order you want.",
 o1h:"What's there, in what order", o1:"For each kind of file and each wheel, tick the actions to show and drag them into your order.",
 o2h:"With which keys", o2:"Each wheel has its own combination: one or two keys among ⌃ ⌥ ⇧ ⌘.",
 o3h:"How it looks", o3:"Slice shape, size and accent colour. On the Share wheel you add your own apps.",
 ge_h:"Three gestures, three wheels", ge_l:"These are the default keys: you can change them in Settings.",
 ge1h:"Convert", ge1:"The output formats for that kind of file.",
 ge2h:"Tools", ge2:"Compress, resize, merge, split, edit…",
 ge3h:"Share", ge3:"AirDrop, Messages, Mail, Telegram, WhatsApp, Copy, Terminal and the apps you add.",
 fm_h:"What you can transform", fm_s:"Supported files", fm_c:"Convert to (⇧)", fm_t:"Tools (⌥⇧)",
 tab_img:"Images", tab_pdf:"PDF", tab_vid:"Video", tab_aud:"Audio", tab_doc:"Documents", tab_xls:"Spreadsheets", tab_pres:"Presentations", tab_sub:"Subtitles", tab_arc:"Archives",
 t_img:"Compress · target file size · 50% or pixel sizes · rotate · mirror · remove background (macOS 14+) · text with OCR · QR codes · strip metadata · edit (light and colour, crop, draw, arrows, text, cover) · lay out 2 or more photos · PDF · ZIP, also protected",
 t_pdf:"Compress · target file size · merge · organize pages · split · OCR (searchable PDF) · password and unlock · page numbers · watermark",
 t_vid:"Trim · 1080p · 720p · target file size · HEVC · 2× / 0.5× speed · join · snapshot · mute · audio only · strip metadata · subtitles from speech (macOS 26+)",
 t_aud:"Trim · normalize · mono · compress · strip metadata · subtitles from speech (macOS 26+) · ZIP",
 t_doc:"Translate into Italian, English and French (macOS 15+) · ZIP",
 t_xls:"ZIP", t_pres:"Read or strip metadata · ZIP",
 t_sub:"Translate into Italian, English and French (macOS 15+) · ZIP",
 t_arc:"Extract · unlock and extract password-protected ZIPs · protected ZIP",
 x_ext:"Extract",
 also:"Translation uses Apple's service, which according to Apple works on the device.",
 in_h:"Install it in a minute", in_l:"Rondelle is free and isn't notarized by Apple, so macOS 15 and later block the first opening. The disk image has a quick fix: no trip to System Settings.",
 s1h:"1 · Download", s1:"Open the .dmg and drag Rondelle onto Applications.",
 s2h:"2 · Open Terminal", s2:"Double-click Open Terminal in the same window. It is only a shortcut to the Terminal app that comes with your Mac.",
 s3h:"3 · Allow Opening", s3:"Drag Allow Opening from the window into Terminal and press Return. Rondelle opens.",
 s4h:"4 · Use", s4:"The ring appears in the menu bar and the tutorial starts.", in_n:"What Allow Opening does: it removes the download mark macOS puts on Rondelle, only on Rondelle, then opens it. It needs no password and sends nothing anywhere. It is a plain text file: you can read it first. Prefer not to use Terminal? System Settings → Privacy & Security → Open Anyway (on macOS 13 and 14: right-click the app → Open). Updating? Quit Rondelle and drag the new one onto Applications.",
 cta_h:"Every file has a way out.", cta_small:"Version and date from the latest release",
 cta_links:"<a href=\"https://github.com/jackb998/rondelle/releases/latest\" rel=\"noopener\">Release notes</a> · <a href=\"https://github.com/jackb998/rondelle/releases/latest\" rel=\"noopener\">SHA-256</a> · <a href=\"https://github.com/jackb998/rondelle/releases\" rel=\"noopener\">Previous versions</a> · <a href=\"https://github.com/jackb998/rondelle\" rel=\"noopener\">Code on GitHub</a>",
 f1h:"Rondelle", f1:"A free menu bar app for macOS. Open source under the MIT licence.",
 f2h:"Privacy", f2:"Conversions stay on your Mac: no file is uploaded. The app uses the network only to check for updates (once a day, can be turned off) and for the contact form, when you press Send. Translation uses Apple's service, which according to Apple works on the device.",
 f2l:"<a href=\"https://github.com/jackb998/rondelle#privacy-and-security\" rel=\"noopener\">Full policy</a> · <a href=\"https://github.com/jackb998/rondelle/security/policy\" rel=\"noopener\">Security</a>",
 f3h:"Contact", f3:"Write from the form in Settings or open an issue on GitHub.", f3l:"Support Rondelle · Buy me a coffee",
 foot:"Rondelle · MIT licence",
 /* press */
 p_h:"Press kit", p_l:"Text, symbol and colours to talk about Rondelle.",
 p_b1:"In one sentence", p_b1t:"Rondelle is a file converter and toolkit for macOS: drag a file and choose where it comes out, from a wheel you arrange yourself.",
 p_b2:"Description", p_b2t:"File tools, thoughtfully arranged.", p_b3:"Signature", p_b3t:"Every file has a way out.",
 p_i:"The idea",
 p_i1:"Drag a file in Finder, hold ⇧ Shift and choose from a wheel where it comes out. The new file lands in the same folder; the original stays as it is.",
 p_i2:"You arrange the wheel: for each kind of file you decide which actions to show and in what order, with which keys to open it and how it should look.",
 p_i3:"The name comes from the washer, a ring with a hole in the middle. The symbol takes the ring, opens it and lets a green dot out: the file taking its own way.",
 p_w:"How it works",
 p_w1:"Three gestures, three wheels: ⇧ to convert, ⌥⇧ for tools, ⌃⇧ to share. These are the default keys and can be changed. Conversions happen on the Mac: the part of the app that reads files has no network access.",
 p_w2:"<strong>In short:</strong> free, open source under the MIT licence, macOS 13 or later, Apple silicon and Intel, in Italian, English and French.",
 p_n:"How to write the name",
 p_n1:"<strong>Rondelle</strong>, capital R, no article: “Rondelle converts…”.",
 p_n2:"Unchanged in every language, even where “rondelle” is a plural.",
 p_v:"Main versions", p_v1:"<b>1.0</b><i>launch</i><p>First public release: the wheel, three gestures, interactive tutorial, 3 languages.</p>",
 p_v2:"All the changes are in the release notes on GitHub.",
 p_m:"Materials", p_m1:"Symbol on light<br>SVG", p_m2:"Symbol on black<br>SVG", p_m3:"Monochrome<br>SVG black and paper", p_m4:"App icon<br>PNG 1024",
 p_m5:"Also the animated tutorial, light and dark (GIF). Screenshots on request.",
 p_c:"Colours", c1:"Black<br>Text, dark backgrounds", c2:"Paper<br>Light backgrounds", c3:"Green<br>Accent on black, also text", c4:"Green<br>Graphics on paper, not text", c5:"Grey<br>Borders on light",
 p_u:"Using the symbol",
 p_u1:"Don't rotate it: the opening and the dot always stay top right.",
 p_u2:"The dot is green, or the same colour as the ring in the monochrome version.",
 p_u3:"No slices, shadows, outlines or circles around it. Free space around it at least the size of the dot.",
 p_f2:"Conversions stay on your Mac: no file is uploaded.", p_f3:"Form in Settings or an issue on GitHub.",
n_guide:"App guide",
title_guide:"Rondelle · App guide",
n_support:"Help",
sp_h:"Help",
title_support:"Rondelle · Help",
sp_l:"Install it, check what it needs, and write to us if something is wrong.",
n_coffee:"Support us",
title_supportus:"Rondelle · Support us",
su_h:"Support us",
su_l:"Rondelle is free for now, and paid for by the people who make it.",
su_p1:"Rondelle is a small project. Using it costs nothing today, and the work on it is paid for out of our own pockets.",
su_p2:"If you like it and want to help it grow, you can chip in with a coffee. It goes into the time we spend on development.",
su_p3:"There is no obligation and nothing is locked behind it: the app is the same whether you chip in or not.",
su_btn:"Buy me a coffee",
su_note:"The button opens Buy Me a Coffee in a new tab. The pop-up in the corner of this page is loaded from their servers, and only on this page.",

},
it: {
 title_press:"Rondelle · Press kit",
 meta:"Rondelle è un convertitore e toolkit di file per macOS: trascini un file e scegli dove farlo uscire, da una ruota che disponi tu.",
 n_how:"Come funziona", n_fmt:"Formati", n_priv:"Privacy", n_press:"Press kit", n_sup:"Sostieni", n_home:"← Home",
 tag:"Gli strumenti per i tuoi file, ben disposti.",
 lead:"<span class=\"q\">Quale sito uso per convertire questo file? È sicuro? Perché mi chiede di registrarmi?</span><strong>Salta tutto.</strong><span>Trascina il file, tieni premuto ⇧ Shift, scegli il formato. Succede sul tuo Mac: non carichi niente.</span>",
 dl:"⬇ Scarica Rondelle", small:"Gratis · codice aperto (MIT) · macOS 13 o successivo · Apple silicon e Intel",
 hint:"Con <kbd>⇧ Shift</kbd> premuto la ruota mostra i formati di quel file: quello scelto esce dall’anello. Passa sopra la ruota per provare.",
 g1h:"Un gesto, nessuna app da aprire", g1:"La ruota compare mentre trascini e mostra solo quello che si può fare con quel file.",
 g2h:"Sul tuo Mac", g2:"Nessun file viene caricato. La parte che legge i file non ha accesso alla rete.",
 g3h:"Accanto all’originale", g3:"Il nuovo file compare nella stessa cartella, l’originale resta com’è.",
 own_h:"La ruota la disponi tu", own_l:"Non un elenco di funzioni da scorrere: per ogni tipo di file tieni solo quello che usi, nell’ordine che vuoi.",
 o1h:"Cosa c’è e in che ordine", o1:"Per ogni tipo di file e ogni ruota spunti le azioni da mostrare e le trascini nel tuo ordine.",
 o2h:"Con quali tasti", o2:"Ogni ruota ha la sua combinazione: uno o due tasti tra ⌃ ⌥ ⇧ ⌘.",
 o3h:"Come appare", o3:"Forma degli spicchi, grandezza e colore d’accento. Sulla ruota Condividi aggiungi le tue app.",
 ge_h:"Tre gesti, tre ruote", ge_l:"Questi sono i tasti predefiniti: puoi cambiarli nelle Impostazioni.",
 ge1h:"Converti", ge1:"I formati di uscita per quel tipo di file.",
 ge2h:"Strumenti", ge2:"Comprimi, ridimensiona, unisci, dividi, modifica…",
 ge3h:"Condividi", ge3:"AirDrop, Messaggi, Mail, Telegram, WhatsApp, Copia, Terminale e le app che aggiungi.",
 fm_h:"Cosa puoi trasformare", fm_s:"File supportati", fm_c:"Converti in (⇧)", fm_t:"Strumenti (⌥⇧)",
 tab_img:"Immagini", tab_pdf:"PDF", tab_vid:"Video", tab_aud:"Audio", tab_doc:"Documenti", tab_xls:"Fogli di calcolo", tab_pres:"Presentazioni", tab_sub:"Sottotitoli", tab_arc:"Archivi",
 t_img:"Comprimi · peso target · 50% o misure in pixel · ruota · specchia · rimuovi sfondo (macOS 14+) · testo con OCR · codici QR · togli metadati · modifica (luce e colore, ritaglio, disegno, frecce, testo, copri) · impagina 2 o più foto · PDF · ZIP, anche protetto",
 t_pdf:"Comprimi · peso target · unisci · organizza le pagine · dividi · OCR (PDF ricercabile) · password e sblocco · numeri di pagina · filigrana",
 t_vid:"Taglia · 1080p · 720p · peso target · HEVC · velocità 2× / 0,5× · unisci · fotogramma · muto · solo audio · togli metadati · sottotitoli dalla voce (macOS 26+)",
 t_aud:"Taglia · normalizza · mono · comprimi · togli metadati · sottotitoli dalla voce (macOS 26+) · ZIP",
 t_doc:"Traduci in italiano, inglese e francese (macOS 15+) · ZIP",
 t_xls:"ZIP", t_pres:"Leggi o rimuovi i metadati · ZIP",
 t_sub:"Traduci in italiano, inglese e francese (macOS 15+) · ZIP",
 t_arc:"Estrai · sblocca ed estrai gli ZIP con password · ZIP protetto",
 x_ext:"Estrai",
 also:"La traduzione usa il servizio di Apple, che secondo Apple lavora sul dispositivo.",
 in_h:"Installala in un minuto", in_l:"Rondelle è gratis e non è autenticata da Apple, quindi macOS 15 e successivi bloccano la prima apertura. L’immagine disco ha una soluzione rapida: niente Impostazioni di Sistema.",
 s1h:"1 · Scarica", s1:"Apri il .dmg e trascina Rondelle su Applicazioni.",
 s2h:"2 · Apri Terminale", s2:"Fai doppio clic su Open Terminal nella stessa finestra. È solo una scorciatoia al Terminale che c’è già nel tuo Mac.",
 s3h:"3 · Consenti l’apertura", s3:"Trascina Allow Opening dalla finestra dentro il Terminale e premi Invio. Rondelle si apre.",
 s4h:"4 · Usa", s4:"L’anello compare nella barra dei menu e parte il tutorial.", in_n:"Cosa fa Allow Opening: toglie a Rondelle, e solo a Rondelle, il segno di download che macOS applica ai file scaricati, poi la apre. Non chiede password e non invia nulla. È un semplice file di testo: puoi leggerlo prima. Non vuoi usare il Terminale? Impostazioni di Sistema → Privacy e sicurezza → Apri comunque (su macOS 13 e 14: clic destro sull’app → Apri). Aggiorni? Chiudi Rondelle e trascina la nuova su Applicazioni.",
 cta_h:"Ogni file ha la sua uscita.", cta_small:"Versione e data dall’ultima release",
 cta_links:"<a href=\"https://github.com/jackb998/rondelle/releases/latest\" rel=\"noopener\">Note di rilascio</a> · <a href=\"https://github.com/jackb998/rondelle/releases/latest\" rel=\"noopener\">SHA-256</a> · <a href=\"https://github.com/jackb998/rondelle/releases\" rel=\"noopener\">Versioni precedenti</a> · <a href=\"https://github.com/jackb998/rondelle\" rel=\"noopener\">Codice su GitHub</a>",
 f1:"Un’app gratuita per la barra dei menu di macOS. Codice aperto con licenza MIT.",
 f2:"Le conversioni restano sul tuo Mac: nessun file viene caricato. L’app usa la rete solo per controllare gli aggiornamenti (una volta al giorno, disattivabile) e per il modulo di contatto, quando premi Invia. La traduzione usa il servizio di Apple, che secondo Apple lavora sul dispositivo.",
 f2l:"<a href=\"https://github.com/jackb998/rondelle#privacy-and-security\" rel=\"noopener\">Informativa completa</a> · <a href=\"https://github.com/jackb998/rondelle/security/policy\" rel=\"noopener\">Sicurezza</a>",
 f3h:"Contatti", f3:"Scrivi dal modulo in Impostazioni o apri una segnalazione su GitHub.", f3l:"Sostieni Rondelle · Buy me a coffee",
 foot:"Rondelle · Licenza MIT",
 p_l:"Testi, simbolo e colori per parlare di Rondelle.",
 p_b1:"In una frase", p_b1t:"Rondelle è un convertitore e toolkit di file per macOS: trascini un file e scegli dove farlo uscire, da una ruota che disponi tu.",
 p_b2:"Descrizione", p_b2t:"Gli strumenti per i tuoi file, ben disposti.", p_b3:"Firma", p_b3t:"Ogni file ha la sua uscita.",
 p_i:"L’idea",
 p_i1:"Trascini un file nel Finder, tieni premuto ⇧ Shift e da una ruota scegli dove farlo uscire. Il nuovo file compare nella stessa cartella, l’originale resta com’è.",
 p_i2:"La ruota la disponi tu: per ogni tipo di file decidi quali azioni mostrare e in che ordine, con quali tasti aprirla e che aspetto deve avere.",
 p_i3:"Il nome viene dalla rondella, un anello con un foro al centro. Il simbolo riprende l’anello, lo apre e ne fa uscire un pallino verde: il file che prende la sua strada.",
 p_w:"Come lavora",
 p_w1:"Tre gesti, tre ruote: ⇧ per convertire, ⌥⇧ per gli strumenti, ⌃⇧ per condividere. Sono i tasti predefiniti e si possono cambiare. Le conversioni avvengono sul Mac: la parte dell’app che legge i file non ha accesso alla rete.",
 p_w2:"<strong>In breve:</strong> gratis, codice aperto con licenza MIT, macOS 13 o successivo, Apple silicon e Intel, in italiano, inglese e francese.",
 p_n:"Come scrivere il nome",
 p_n1:"<strong>Rondelle</strong>, con la R maiuscola e senza articolo: «Rondelle converte…», non «la Rondelle».",
 p_n2:"Invariato in tutte le lingue, anche dove «rondelle» è un plurale.",
 p_v:"Versioni principali", p_v1:"<b>1.0</b><i>lancio</i><p>Primo rilascio pubblico: ruota, tre gesti, tutorial interattivo, 3 lingue.</p>",
 p_v2:"Tutte le novità sono nelle note di rilascio su GitHub.",
 p_m:"Materiali", p_m1:"Simbolo su chiaro<br>SVG", p_m2:"Simbolo su nero<br>SVG", p_m3:"Monocromo<br>SVG nero e carta", p_m4:"Icona dell’app<br>PNG 1024",
 p_m5:"Anche il tutorial animato, chiaro e scuro (GIF). Schermate su richiesta.",
 p_c:"Colori", c1:"Nero<br>Testo, fondi scuri", c2:"Carta<br>Fondi chiari", c3:"Verde<br>Accento su nero, anche testo", c4:"Verde<br>Grafica su carta, non testo", c5:"Grigio<br>Bordi su chiaro",
 p_u:"Uso del simbolo",
 p_u1:"Non ruotarlo: l’apertura e il pallino stanno sempre in alto a destra.",
 p_u2:"Il pallino è verde, oppure dello stesso colore dell’anello nella versione monocroma.",
 p_u3:"Niente spicchi, ombre, contorni o cerchi intorno. Spazio libero tutt’intorno pari almeno al pallino.",
 p_f2:"Le conversioni restano sul tuo Mac: nessun file viene caricato.", p_f3:"Modulo in Impostazioni o segnalazione su GitHub.",
n_guide:"Guida all’app",
title_guide:"Rondelle · Guida all’app",
n_support:"Aiuto",
sp_h:"Aiuto",
title_support:"Rondelle · Aiuto",
sp_l:"Installala, controlla cosa richiede e scrivici se qualcosa non va.",
n_coffee:"Sostienici",
title_supportus:"Rondelle · Sostienici",
su_h:"Sostienici",
su_l:"Rondelle è gratuita, per ora, e la pagano di tasca propria le persone che la fanno.",
su_p1:"Rondelle è un piccolo progetto. Usarla oggi non costa nulla, e il lavoro che c’è dietro è autofinanziato.",
su_p2:"Se ti piace e vuoi aiutarla a crescere, puoi contribuire con un caffè. Va al tempo che dedichiamo allo sviluppo.",
su_p3:"Non c’è nessun obbligo e nulla è bloccato dietro: l’app è la stessa, che tu contribuisca o no.",
su_btn:"Offrimi un caffè",
su_note:"Il pulsante apre Buy Me a Coffee in una nuova scheda. Il pop-up nell’angolo di questa pagina viene caricato dai loro server, e solo in questa pagina.",

},
fr: { /* TODO: to be reviewed by a native speaker; the site addresses the reader with «vous» */
 title_press:"Rondelle · Dossier de presse",
 meta:"Rondelle est un convertisseur et une boîte à outils de fichiers pour macOS : vous faites glisser un fichier et choisissez où le faire sortir, depuis une roue que vous disposez vous-même.",
 n_how:"Fonctionnement", n_fmt:"Formats", n_priv:"Confidentialité", n_press:"Dossier de presse", n_sup:"Soutenir", n_home:"← Accueil",
 tag:"Des outils pour fichiers, bien disposés.",
 lead:"<span class=\"q\">Quel site utiliser pour convertir ce fichier ? Est-il sûr ? Pourquoi demande-t-il de créer un compte ?</span><strong>Oubliez tout ça.</strong><span>Faites glisser le fichier, maintenez ⇧ Maj, choisissez le format. Ça se passe sur votre Mac : rien n’est envoyé.</span>",
 dl:"⬇ Télécharger Rondelle", small:"Gratuit · open source (MIT) · macOS 13 ou ultérieur · Apple silicon et Intel",
 hint:"Avec <kbd>⇧ Maj</kbd> maintenue, la roue affiche les formats de ce fichier : celui que vous choisissez sort de l’anneau. Survolez la roue pour essayer.",
 g1h:"Un geste, aucune app à ouvrir", g1:"La roue apparaît pendant le glissement et n’affiche que ce qu’on peut faire avec ce fichier.",
 g2h:"Sur votre Mac", g2:"Aucun fichier n’est envoyé. La partie qui lit vos fichiers n’a pas accès au réseau.",
 g3h:"À côté de l’original", g3:"Le nouveau fichier arrive dans le même dossier ; l’original reste tel quel.",
 own_h:"La roue, c’est vous qui la disposez", own_l:"Pas une liste de fonctions à parcourir : pour chaque type de fichier, vous ne gardez que ce que vous utilisez, dans l’ordre voulu.",
 o1h:"Ce qui s’y trouve, et dans quel ordre", o1:"Pour chaque type de fichier et chaque roue, vous cochez les actions à afficher et vous les glissez dans votre ordre.",
 o2h:"Avec quelles touches", o2:"Chaque roue a sa combinaison : une ou deux touches parmi ⌃ ⌥ ⇧ ⌘.",
 o3h:"Son apparence", o3:"Forme des parts, taille et couleur d’accent. Sur la roue Partager, vous ajoutez vos propres apps.",
 ge_h:"Trois gestes, trois roues", ge_l:"Ce sont les touches par défaut : vous pouvez les changer dans les Réglages.",
 ge1h:"Convertir", ge1:"Les formats de sortie pour ce type de fichier.",
 ge2h:"Outils", ge2:"Compresser, redimensionner, fusionner, diviser, modifier…",
 ge3h:"Partager", ge3:"AirDrop, Messages, Mail, Telegram, WhatsApp, Copier, Terminal et les apps que vous ajoutez.",
 fm_h:"Ce que vous pouvez transformer", fm_s:"Fichiers pris en charge", fm_c:"Convertir en (⇧)", fm_t:"Outils (⌥⇧)",
 tab_img:"Images", tab_pdf:"PDF", tab_vid:"Vidéo", tab_aud:"Audio", tab_doc:"Documents", tab_xls:"Tableurs", tab_pres:"Présentations", tab_sub:"Sous-titres", tab_arc:"Archives",
 t_img:"Compresser · poids cible · 50 % ou tailles en pixels · pivoter · miroir · supprimer l’arrière-plan (macOS 14+) · texte par OCR · codes QR · retirer les métadonnées · modifier (lumière et couleur, recadrage, dessin, flèches, texte, masquer) · mettre en page 2 photos ou plus · PDF · ZIP, même protégé",
 t_pdf:"Compresser · poids cible · fusionner · organiser les pages · diviser · OCR (PDF interrogeable) · mot de passe et déverrouillage · numéros de page · filigrane",
 t_vid:"Couper · 1080p · 720p · poids cible · HEVC · vitesse 2× / 0,5× · assembler · image fixe · muet · audio seul · retirer les métadonnées · sous-titres depuis la voix (macOS 26+)",
 t_aud:"Couper · normaliser · mono · compresser · retirer les métadonnées · sous-titres depuis la voix (macOS 26+) · ZIP",
 t_doc:"Traduire en italien, anglais et français (macOS 15+) · ZIP",
 t_xls:"ZIP", t_pres:"Lire ou supprimer les métadonnées · ZIP",
 t_sub:"Traduire en italien, anglais et français (macOS 15+) · ZIP",
 t_arc:"Extraire · déverrouiller et extraire les ZIP protégés · ZIP protégé",
 x_ext:"Extraire",
 also:"La traduction utilise le service d’Apple, qui, selon Apple, fonctionne sur l’appareil.",
 in_h:"Installez-la en une minute", in_l:"Rondelle est gratuite et n’est pas notariée par Apple : macOS 15 et suivants bloquent la première ouverture. L’image disque a une solution rapide, sans passer par les Réglages Système.",
 s1h:"1 · Télécharger", s1:"Ouvrez le .dmg et faites glisser Rondelle sur Applications.",
 s2h:"2 · Ouvrir Terminal", s2:"Double-cliquez sur Open Terminal dans la même fenêtre. C’est seulement un raccourci vers l’app Terminal déjà présente sur votre Mac.",
 s3h:"3 · Autoriser l’ouverture", s3:"Faites glisser Allow Opening de la fenêtre dans Terminal et appuyez sur Retour. Rondelle s’ouvre.",
 s4h:"4 · Utiliser", s4:"L’anneau apparaît dans la barre des menus et le tutoriel démarre.", in_n:"Ce que fait Allow Opening : il retire de Rondelle, et seulement d’elle, la marque de téléchargement que macOS pose sur les fichiers téléchargés, puis l’ouvre. Aucun mot de passe, rien n’est envoyé. C’est un simple fichier texte : vous pouvez le lire avant. Vous préférez éviter Terminal ? Réglages Système → Confidentialité et sécurité → Ouvrir quand même (sous macOS 13 et 14 : clic droit sur l’app → Ouvrir). Mise à jour ? Quittez Rondelle et faites glisser la nouvelle sur Applications.",
 cta_h:"Chaque fichier a sa sortie.", cta_small:"Version et date de la dernière version publiée",
 cta_links:"<a href=\"https://github.com/jackb998/rondelle/releases/latest\" rel=\"noopener\">Notes de version</a> · <a href=\"https://github.com/jackb998/rondelle/releases/latest\" rel=\"noopener\">SHA-256</a> · <a href=\"https://github.com/jackb998/rondelle/releases\" rel=\"noopener\">Versions précédentes</a> · <a href=\"https://github.com/jackb998/rondelle\" rel=\"noopener\">Code sur GitHub</a>",
 f1:"Une app gratuite pour la barre des menus de macOS. Open source sous licence MIT.",
 f2:"Les conversions restent sur votre Mac : aucun fichier n’est envoyé. L’app n’utilise le réseau que pour rechercher les mises à jour (une fois par jour, désactivable) et pour le formulaire de contact, quand vous appuyez sur Envoyer. La traduction utilise le service d’Apple, qui, selon Apple, fonctionne sur l’appareil.",
 f2l:"<a href=\"https://github.com/jackb998/rondelle#privacy-and-security\" rel=\"noopener\">Politique complète</a> · <a href=\"https://github.com/jackb998/rondelle/security/policy\" rel=\"noopener\">Sécurité</a>", f2h:"Confidentialité",
 f3h:"Contact", f3:"Écrivez depuis le formulaire des Réglages ou ouvrez un ticket sur GitHub.", f3l:"Soutenir Rondelle · Buy me a coffee",
 foot:"Rondelle · Licence MIT",
 p_h:"Dossier de presse", p_l:"Textes, symbole et couleurs pour parler de Rondelle.",
 p_b1:"En une phrase", p_b1t:"Rondelle est un convertisseur et une boîte à outils de fichiers pour macOS : vous faites glisser un fichier et choisissez où le faire sortir, depuis une roue que vous disposez vous-même.",
 p_b2:"Description", p_b2t:"Des outils pour fichiers, bien disposés.", p_b3:"Signature", p_b3t:"Chaque fichier a sa sortie.",
 p_i:"L’idée",
 p_i1:"Vous faites glisser un fichier dans le Finder, maintenez ⇧ Maj et choisissez sur une roue où le faire sortir. Le nouveau fichier arrive dans le même dossier ; l’original reste tel quel.",
 p_i2:"La roue, c’est vous qui la disposez : pour chaque type de fichier, vous décidez quelles actions afficher et dans quel ordre, avec quelles touches l’ouvrir et quel aspect lui donner.",
 p_i3:"Le nom vient de la rondelle, un anneau percé en son centre. Le symbole reprend l’anneau, l’ouvre et en fait sortir un point vert : le fichier qui prend son chemin.",
 p_w:"Fonctionnement",
 p_w1:"Trois gestes, trois roues : ⇧ pour convertir, ⌥⇧ pour les outils, ⌃⇧ pour partager. Ce sont les touches par défaut, modifiables. Les conversions se font sur le Mac : la partie de l’app qui lit les fichiers n’a pas accès au réseau.",
 p_w2:"<strong>En bref :</strong> gratuite, open source sous licence MIT, macOS 13 ou ultérieur, Apple silicon et Intel, en italien, anglais et français.",
 p_n:"Comment écrire le nom",
 p_n1:"<strong>Rondelle</strong>, avec une majuscule et sans article : « Rondelle convertit… ».",
 p_n2:"Inchangé dans toutes les langues, même là où « rondelle » est un pluriel.",
 p_v:"Versions principales", p_v1:"<b>1.0</b><i>lancement</i><p>Première version publique : la roue, trois gestes, tutoriel interactif, 3 langues.</p>",
 p_v2:"Toutes les nouveautés figurent dans les notes de version sur GitHub.",
 p_m:"Ressources", p_m1:"Symbole sur clair<br>SVG", p_m2:"Symbole sur noir<br>SVG", p_m3:"Monochrome<br>SVG noir et papier", p_m4:"Icône de l’app<br>PNG 1024",
 p_m5:"Aussi le tutoriel animé, clair et sombre (GIF). Captures d’écran sur demande.",
 p_c:"Couleurs", c1:"Noir<br>Texte, fonds sombres", c2:"Papier<br>Fonds clairs", c3:"Vert<br>Accent sur noir, texte aussi", c4:"Vert<br>Graphisme sur papier, pas de texte", c5:"Gris<br>Bordures sur clair",
 p_u:"Utilisation du symbole",
 p_u1:"Ne le faites pas pivoter : l’ouverture et le point restent toujours en haut à droite.",
 p_u2:"Le point est vert, ou de la même couleur que l’anneau dans la version monochrome.",
 p_u3:"Pas de parts, d’ombres, de contours ni de cercles autour. Espace libre d’au moins la taille du point.",
 p_f2:"Les conversions restent sur votre Mac : aucun fichier n’est envoyé.", p_f3:"Formulaire des Réglages ou ticket sur GitHub.",
n_guide:"Guide de l’app",
title_guide:"Rondelle · Guide de l’app",
n_support:"Aide",
sp_h:"Aide",
title_support:"Rondelle · Aide",
sp_l:"Installez-la, vérifiez ce qu’il lui faut et écrivez-nous si quelque chose ne va pas.",
n_coffee:"Nous soutenir",
title_supportus:"Rondelle · Nous soutenir",
su_h:"Nous soutenir",
su_l:"Rondelle est gratuite pour l’instant, et payée de leur poche par celles et ceux qui la font.",
su_p1:"Rondelle est un petit projet. L’utiliser ne coûte rien aujourd’hui, et le travail qui est derrière est autofinancé.",
su_p2:"Si elle vous plaît et que vous voulez l’aider à grandir, vous pouvez contribuer avec un café. Cela va au temps que nous consacrons au développement.",
su_p3:"Aucune obligation, et rien n’est verrouillé : l’app est la même, que vous contribuiez ou non.",
su_btn:"Offrez-moi un café",
su_note:"Le bouton ouvre Buy Me a Coffee dans un nouvel onglet. La fenêtre dans le coin de cette page est chargée depuis leurs serveurs, et seulement sur cette page.",

}};

const P = {
en:{m_conv:"Convert (⇧)", m_tools:"Tools (⌥⇧)", m_share:"Share (⌃⇧)", wn_conv:"Convert", wn_tools:"Tools", wn_share:"Share",
 play_h:"Try it right here", sel_h:"Select your file type", empty:"Pick a file type to get a file to play with.",
 play_l:"Pick a file type, then drag the file onto the wheel. Pick a wheel with the buttons, or hold ⇧, ⌥⇧ or ⌃⇧ while you drag, like in the app.",
 play_hint:"Drop on a slice to use it, in the centre to cancel. Nothing is uploaded: this is only a demo.", done:"Created next to the original:", sent:"Shared via", n_app:"App", n_support:"Support", n_story:"Story", n_coffee:"Buy me a coffee", sp_h:"Support", sp_l:"Install it, check what it needs, and find where to ask.", rq_h:"Requirements", rq:"macOS 13 or later, Apple silicon and Intel. A few tools need a newer macOS: Remove background 14+, Translate 15+, subtitles from speech 26+, Liquid Glass look 26+.", st_h:"Story", st_l:"How Rondelle began, what it is for, and where the name comes from.", cf_h:"Support Rondelle", cf:"Rondelle is free. If it is useful, you can say thanks with a coffee.", ft_pages:"Pages", fm_l:"Pick a kind of file to see what goes in and what comes out.", p_open:"For press", p_open1:"Logo, colours and short texts to write about Rondelle are in the press kit.", pk_l:"Open the press kit →", title_support:"Rondelle · Support", title_story:"Rondelle · Story", mac:"Your files", skip:"Skip to content", kb_hint:"No mouse? Tab to the file, press Enter, choose with ← →, Enter to confirm, Esc to cancel."},
it:{m_conv:"Converti (⇧)", m_tools:"Strumenti (⌥⇧)", m_share:"Condividi (⌃⇧)", wn_conv:"Converti", wn_tools:"Strumenti", wn_share:"Condividi",
 play_h:"Provala qui", sel_h:"Scegli il tipo di file", empty:"Scegli un tipo di file per avere un file con cui giocare.",
 play_l:"Scegli un tipo di file, poi trascinalo sulla ruota. Scegli la ruota con i pulsanti, oppure tieni premuto ⇧, ⌥⇧ o ⌃⇧ mentre trascini, come nell’app.",
 play_hint:"Rilascia su uno spicchio per usarlo, al centro per annullare. Non viene caricato nulla: è solo una demo.", done:"Creato accanto all’originale:", sent:"Condiviso con", n_app:"App", n_support:"Supporto", n_story:"Storia", n_coffee:"Offrimi un caffè", sp_h:"Supporto", sp_l:"Installala, controlla cosa richiede e scopri dove chiedere aiuto.", rq_h:"Requisiti", rq:"macOS 13 o successivo, Apple silicon e Intel. Alcuni strumenti richiedono un macOS più recente: Rimuovi sfondo 14+, Traduci 15+, sottotitoli dalla voce 26+, aspetto Liquid Glass 26+.", st_h:"Storia", st_l:"Come è nata Rondelle, a cosa serve e da dove viene il nome.", cf_h:"Sostieni Rondelle", cf:"Rondelle è gratuita. Se ti è utile, puoi ringraziare con un caffè.", ft_pages:"Pagine", fm_l:"Scegli un tipo di file per vedere cosa entra e cosa esce.", p_open:"Per la stampa", p_open1:"Logo, colori e testi brevi per scrivere di Rondelle sono nel press kit.", pk_l:"Apri il press kit →", title_support:"Rondelle · Supporto", title_story:"Rondelle · Storia", mac:"I tuoi file", skip:"Vai al contenuto", kb_hint:"Senza mouse? Vai al file con Tab, premi Invio, scegli con ← →, Invio per confermare, Esc per annullare."},
fr:{m_conv:"Convertir (⇧)", m_tools:"Outils (⌥⇧)", m_share:"Partager (⌃⇧)", wn_conv:"Convertir", wn_tools:"Outils", wn_share:"Partager",
 play_h:"Essayez ici", sel_h:"Choisissez le type de fichier", empty:"Choisissez un type de fichier pour avoir un fichier à essayer.",
 play_l:"Choisissez un type de fichier, puis faites-le glisser sur la roue. Choisissez la roue avec les boutons, ou maintenez ⇧, ⌥⇧ ou ⌃⇧ pendant le glissement, comme dans l’app.",
 play_hint:"Relâchez sur une part pour l’utiliser, au centre pour annuler. Rien n’est envoyé : ce n’est qu’une démo.", done:"Créé à côté de l’original :", sent:"Partagé via", n_app:"App", n_support:"Assistance", n_story:"Histoire", n_coffee:"Offrez-moi un café", sp_h:"Assistance", sp_l:"Installez-la, vérifiez ce qu’il lui faut et trouvez où demander de l’aide.", rq_h:"Prérequis", rq:"macOS 13 ou plus récent, Apple silicon et Intel. Quelques outils demandent un macOS plus récent : Supprimer l’arrière-plan 14+, Traduire 15+, sous-titres à partir de la voix 26+, aspect Liquid Glass 26+.", st_h:"Histoire", st_l:"Comment Rondelle est née, à quoi elle sert et d’où vient son nom.", cf_h:"Soutenir Rondelle", cf:"Rondelle est gratuite. Si elle vous est utile, vous pouvez dire merci avec un café.", ft_pages:"Pages", fm_l:"Choisissez un type de fichier pour voir ce qui entre et ce qui sort.", p_open:"Pour la presse", p_open1:"Le logo, les couleurs et de courts textes pour parler de Rondelle sont dans le dossier de presse.", pk_l:"Ouvrir le dossier de presse →", title_support:"Rondelle · Assistance", title_story:"Rondelle · Histoire", mac:"Vos fichiers", skip:"Aller au contenu", kb_hint:"Sans souris ? Allez au fichier avec Tab, appuyez sur Entrée, choisissez avec ← →, Entrée pour confirmer, Échap pour annuler."}};
const LAB = {compress:["Compress","Comprimi","Compresser"],half:["50%","50%","50 %"],rotate:["Rotate","Ruota","Pivoter"],mirror:["Mirror","Specchia","Miroir"],ocr:["OCR","OCR","OCR"],edit:["Edit","Modifica","Modifier"],
 merge:["Merge","Unisci","Fusionner"],split:["Split","Dividi","Diviser"],password:["Password","Password","Mot de passe"],watermark:["Watermark","Filigrana","Filigrane"],
 trim:["Trim","Taglia","Couper"],p1080:["1080p","1080p","1080p"],p720:["720p","720p","720p"],speed2:["2× speed","Velocità 2×","Vitesse 2×"],mute:["Mute","Muto","Muet"],audioonly:["Audio only","Solo audio","Audio seul"],
 normalize:["Normalize","Normalizza","Normaliser"],mono:["Mono","Mono","Mono"],nometa:["No metadata","Senza metadati","Sans méta"],zip:["ZIP","ZIP","ZIP"],translate:["Translate","Traduci","Traduire"],
 extract:["Extract","Estrai","Extraire"],unlockx:["Unlock","Sblocca","Débloquer"],zipprot:["Protected ZIP","ZIP protetto","ZIP protégé"],
 airdrop:["AirDrop","AirDrop","AirDrop"],messages:["Messages","Messaggi","Messages"],mail:["Mail","Mail","Mail"],telegram:["Telegram","Telegram","Telegram"],whatsapp:["WhatsApp","WhatsApp","WhatsApp"],copy:["Copy","Copia","Copier"]};
const C = {
en:{ct_h:"Say hi, or tell us what broke", ct_l:"Found a problem, or have an idea? Write it here. It is read by a person.",
 k_problema:"Problem", k_idea:"Idea", k_altro:"Other", ct_msg:"Your message", ct_mail:"Email (optional, only if you want a reply)", ct_send:"Send",
 ct_note:"Sent only when you press Send. Nothing is kept in your browser.", ct_ok:"Sent. Thank you!", ct_wait:"Sending…",
 ct_bad:"Check the message (it can't be empty) and the email address.", ct_busy:"Too many messages right now. Try again later.", ct_err:"It didn't go through. Try again, or open an issue on GitHub."},
it:{ct_h:"Dicci ciao, o cosa non va", ct_l:"Hai trovato un problema o hai un’idea? Scrivila qui. La legge una persona.",
 k_problema:"Problema", k_idea:"Idea", k_altro:"Altro", ct_msg:"Il tuo messaggio", ct_mail:"Email (facoltativa, solo se vuoi una risposta)", ct_send:"Invia",
 ct_note:"Inviato solo quando premi Invia. Nel browser non resta nulla.", ct_ok:"Inviato. Grazie!", ct_wait:"Invio in corso…",
 ct_bad:"Controlla il messaggio (non può essere vuoto) e l’indirizzo email.", ct_busy:"Troppi messaggi in questo momento. Riprova più tardi.", ct_err:"Non è partito. Riprova, oppure apri una segnalazione su GitHub."},
fr:{ct_h:"Dites bonjour, ou ce qui ne va pas", ct_l:"Un problème, une idée ? Écrivez-le ici. C’est une personne qui vous lit.",
 k_problema:"Problème", k_idea:"Idée", k_altro:"Autre", ct_msg:"Votre message", ct_mail:"E-mail (facultatif, seulement si vous voulez une réponse)", ct_send:"Envoyer",
 ct_note:"Envoyé uniquement quand vous appuyez sur Envoyer. Rien n’est conservé dans votre navigateur.", ct_ok:"Envoyé. Merci !", ct_wait:"Envoi en cours…",
 ct_bad:"Vérifiez le message (il ne peut pas être vide) et l’adresse e-mail.", ct_busy:"Trop de messages en ce moment. Réessayez plus tard.", ct_err:"Ça n’est pas parti. Réessayez, ou ouvrez un ticket sur GitHub."}};
const TOOLS = {img:["compress","half","rotate","mirror","ocr","edit"],pdf:["compress","merge","split","ocr","password","watermark"],vid:["trim","p1080","p720","speed2","mute","audioonly"],
 aud:["trim","normalize","mono","compress","nometa","zip"],doc:["translate","zip"],xls:["zip"],pres:["nometa","zip"],sub:["translate","zip"],arc:["extract","unlockx","zipprot"]};
const SHARE = ["airdrop","messages","mail","telegram","whatsapp","copy"];
const KIND = {heic:"img",jpg:"img",png:"img",webp:"img",tiff:"img",gif:"img",bmp:"img",ico:"img",icns:"img",pdf:"pdf",mp4:"vid",mov:"vid",m4v:"vid",m4a:"aud",wav:"aud",aiff:"aud",flac:"aud",mp3:"aud",
 docx:"doc",rtf:"doc",odt:"doc",html:"doc",txt:"doc",pages:"doc",pptx:"pres",xlsx:"xls",ods:"xls",csv:"xls",tsv:"xls",srt:"sub",vtt:"sub",zip:"arc"};
/* missing keys fall back to English */
const TABS = {
 img:{s:"JPG PNG HEIC TIFF GIF BMP WebP AVIF SVG",c:"JPG PNG HEIC WebP TIFF GIF BMP PDF PPTX ICNS ICO"},
 pdf:{s:"PDF",c:"PNG JPG TXT DOCX RTF PPTX"},
 vid:{s:"MP4 MOV M4V",c:"MP4 MOV M4V GIF M4A"},
 aud:{s:"M4A WAV AIFF FLAC MP3",c:"M4A WAV AIFF FLAC MP3"},
 doc:{s:"DOCX DOC RTF ODT HTML TXT MD PAGES",c:"PDF DOCX RTF ODT HTML TXT PAGES"},
 xls:{s:"XLSX ODS CSV TSV",c:"XLSX ODS CSV TSV HTML PDF"},
 pres:{s:"PPTX",c:"PDF PNG JPG TXT"},
 sub:{s:"SRT VTT",c:"SRT VTT TXT"},
 arc:{s:"ZIP TAR GZ TGZ BZ2 XZ RAR 7Z",c:null}
};
const q = new URLSearchParams(location.search);
let lang = ["it","fr"].includes(q.get("lang")) ? q.get("lang") : "en";
let tab = "img";
const LI = {en:0,it:1,fr:2};
const GG = typeof G !== "undefined" ? G : {};
const t = k => (D[lang][k] ?? P[lang][k] ?? GG[lang]?.[k] ?? C[lang]?.[k] ?? D.en[k] ?? P.en[k] ?? GG.en?.[k] ?? C.en?.[k] ?? "");
const chips = s => s.split(" ").map(x => `<span class="chip">${x}</span>`).join("");
function render() {
  document.documentElement.lang = lang;
  document.querySelectorAll("[data-i]").forEach(e => e.innerHTML = t(e.dataset.i));
  document.querySelectorAll("[data-ph]").forEach(e => { e.placeholder = t(e.dataset.ph); e.setAttribute("aria-label", t(e.dataset.ph)); });
  const sb = document.getElementById("sbody"); if (sb) sb.innerHTML = storyHTML();
  const gb = document.getElementById("gbody"); if (gb) gb.innerHTML = guideHTML();
  document.querySelectorAll("img[data-shot]").forEach(i => { const u = "shots/" + i.dataset.shot + "." + lang + ".png?v=2"; if (i.getAttribute("src") !== u) { i.closest("figure").hidden = false; i.src = u; } });
  const home = !!document.getElementById("tabs");
  document.title = t("title_" + (document.body.dataset.page || "home"));
  const m = document.querySelector('meta[name=description]'); if (m) m.content = t("meta");
  document.querySelectorAll("[data-lang]").forEach(a => a.classList.toggle("cur", a.dataset.lang === lang));
  document.querySelectorAll("a[data-keep]").forEach(a => a.href = a.dataset.keep + (lang === "en" ? "" : "?lang=" + lang));
  const here = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".links a[data-keep]").forEach(a => { if (a.dataset.keep === here) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
  if (home) {
    document.querySelectorAll("#tabs button").forEach(s => {const on=s.dataset.tab===tab; s.classList.toggle("on",on); s.setAttribute("aria-pressed",on);});
    const d = TABS[tab];
    document.getElementById("f-s").innerHTML = chips(d.s);
    document.getElementById("f-c").innerHTML = d.c ? chips(d.c) : `<span class="chip">${t("x_ext")}</span>`;
    document.getElementById("f-t").textContent = t("t_" + tab);
  }
  if (typeof playRefresh === "function") playRefresh();
}
document.addEventListener("click", e => {
  const l = e.target.closest("[data-lang]");
  if (l) { e.preventDefault(); lang = l.dataset.lang; history.replaceState(null, "", lang === "en" ? location.pathname + location.hash : "?lang=" + lang + location.hash); render(); }
  const s = e.target.closest("#tabs button"); if (s) { tab = s.dataset.tab; render(); }
});
/* playground: drag a file onto the wheel (Convert / Tools / Share) */
const SAMPLE={img:"photo.heic",pdf:"report.pdf",vid:"clip.mov",aud:"song.mp3",doc:"notes.docx",xls:"budget.xlsx",pres:"slides.pptx",sub:"subtitles.srt",arc:"archive.zip"};
const $=id=>document.getElementById(id);
const stage=$("stage"); let mode="conv", cur=null, items=[], sel=-1, pos={x:0,y:0}, wpx=300;
const kindOf=n=>KIND[n.split(".").pop().toLowerCase()]||"doc";
const lab=k=>LAB[k]?LAB[k][LI[lang]]:k;
function fileEl(n){const e=document.createElement("div");e.className="fi";e.dataset.name=n;e.tabIndex=0;e.setAttribute("role","button");e.setAttribute("aria-label",n);e.innerHTML=`<div class="ic"><b>${n.split(".").pop().toUpperCase()}</b></div><span>${n}</span>`;e.addEventListener("pointerdown",down);e.addEventListener("keydown",kdown);e.addEventListener("blur",()=>kclose());return e;}
function playRefresh(){ if(!stage) return; const r=$("hubrest"); if(r&&sel<0) $("hub").textContent=t("wn_"+mode); document.querySelectorAll("#modes button").forEach(b=>{const on=b.dataset.mode===mode;b.classList.toggle("on",on);b.setAttribute("aria-pressed",on);}); }
function itemsFor(name){
  const ext=name.split(".").pop().toLowerCase(), k=kindOf(name);
  if(mode==="share") return SHARE.map(x=>({k:x,l:lab(x)}));
  if(mode==="tools") return TOOLS[k].map(x=>({k:x,l:lab(x)}));
  const c=TABS[k].c; if(!c) return [{k:"extract",l:lab("extract")}];
  return c.split(" ").filter(x=>x.toLowerCase()!==ext&&!(ext==="jpg"&&x==="JPG")).slice(0,8).map(x=>({k:x.toLowerCase(),l:x}));
}
function arc(r,a){a*=Math.PI/180;return [(r*Math.cos(a)).toFixed(1),(r*Math.sin(a)).toFixed(1)];}
function build(){
  const N=items.length, g=$("sl"); g.innerHTML="";
  items.forEach((it,i)=>{
    const c=-90+i*360/N, h=N===1?0:180/N-2.2, el=document.createElementNS("http://www.w3.org/2000/svg","g"); el.setAttribute("class","s");
    let d;
    if(N===1) d="M150 0A150 150 0 1 1 -150 0A150 150 0 1 1 150 0ZM57 0A57 57 0 1 0 -57 0A57 57 0 1 0 57 0Z";
    else {const [x0,y0]=arc(150,c-h),[x1,y1]=arc(150,c+h),[x2,y2]=arc(57,c+h),[x3,y3]=arc(57,c-h);d=`M${x0} ${y0}A150 150 0 0 1 ${x1} ${y1}L${x2} ${y2}A57 57 0 0 0 ${x3} ${y3}Z`;}
    const [tx,ty]=arc(103.5,c);
    el.innerHTML=`<path d="${d}" fill-rule="evenodd"/><text x="${tx}" y="${(+ty+4).toFixed(1)}">${it.l}</text>`; g.appendChild(el);
  });
  setSel(-1);
}
function setSel(i){
  sel=i; document.querySelectorAll("#sl .s").forEach((e,j)=>e.classList.toggle("on",j===i));
  const N=items.length, c=i<0?-90:-90+i*360/N, [dx,dy]=arc(63,c), d=$("dot"); d.setAttribute("cx",dx); d.setAttribute("cy",dy);
  $("hub").textContent=i<0?t("wn_"+mode):items[i].l;
}
function place(){
  const R=stage.getBoundingClientRect(); wpx=Math.min(300,R.width-16);
  const mx=R.width/2, my=R.height/2, maxD=Math.max(0,R.width/2-wpx/2-6); let vx=pos.x-mx, vy=pos.y-my; const L=Math.hypot(vx,vy);
  if(L>maxD){vx*=maxD/L;vy*=maxD/L;} const x=mx+vx, y=my+vy;
  const w=$("wh"); w.style.width=wpx+"px"; w.style.left=(x-wpx/2)+"px"; w.style.top=(y-wpx/2)+"px"; w._c={x,y};
}
function modeFrom(e){return e.shiftKey&&e.ctrlKey?"share":e.shiftKey&&e.altKey?"tools":e.shiftKey?"conv":$("modes").dataset.base;}
function down(e){
  if(e.button>0) return; e.preventDefault();
  const R=stage.getBoundingClientRect(); cur=e.currentTarget; cur.setPointerCapture(e.pointerId);
  pos={x:e.clientX-R.left,y:e.clientY-R.top}; mode=modeFrom(e); items=itemsFor(cur.dataset.name);
  const gh=$("ghost"); gh.innerHTML=cur.innerHTML; gh.style.display="block"; cur.classList.add("drag");
  place(); build(); $("wh").style.display="block"; $("toast").style.opacity=0; playRefresh(); move(e);
  cur.onpointermove=move; cur.onpointerup=cur.onpointercancel=up;
}
function move(e){
  const R=stage.getBoundingClientRect(), x=e.clientX-R.left, y=e.clientY-R.top, gh=$("ghost");
  gh.style.transform=`translate(${x-28}px,${y-34}px)`;
  const m=modeFrom(e); if(m!==mode){mode=m; items=itemsFor(cur.dataset.name); build(); playRefresh();}
  const c=$("wh")._c, s=wpx/340, dx=x-c.x, dy=y-c.y, r=Math.hypot(dx,dy)/s;
  if(r<57||r>175){ if(sel!==-1) setSel(-1); return; }
  const N=items.length, a=(((Math.atan2(dy,dx)*180/Math.PI+90)%360)+360)%360, i=Math.round(a/(360/N))%N;
  if(i!==sel) setSel(i);
}
function up(){
  const el=cur, it=sel>=0?items[sel]:null; cur=null; el.onpointermove=el.onpointerup=el.onpointercancel=null;
  finish(el,it);
}
let kb=null;
function kclose(){ if(!kb) return; const el=kb; kb=null; finish(el,null); }
function kdown(e){
  const el=e.currentTarget;
  if(!kb){ if(e.key==="Enter"||e.key===" "){ e.preventDefault(); kb=el; const R=stage.getBoundingClientRect(); pos={x:R.width/2,y:R.height/2}; mode=$("modes").dataset.base; items=itemsFor(el.dataset.name); el.classList.add("drag"); place(); build(); $("wh").style.display="block"; $("toast").style.opacity=0; playRefresh(); setSel(0); say2(items[0].l);} return; }
  const N=items.length;
  if(e.key==="ArrowRight"||e.key==="ArrowDown"){e.preventDefault(); setSel((sel+1)%N); say2(items[sel].l);}
  else if(e.key==="ArrowLeft"||e.key==="ArrowUp"){e.preventDefault(); setSel((sel-1+N)%N); say2(items[sel].l);}
  else if(e.key==="Enter"||e.key===" "){e.preventDefault(); const it=items[sel]; kb=null; finish(el,it);}
  else if(e.key==="Escape"||e.key==="Tab"){ if(e.key==="Escape") e.preventDefault(); kclose(); }
}
function say2(s){ $("sr").textContent=s; }
function finish(el,it){
  const name=el.dataset.name;
  $("wh").style.display="none"; $("ghost").style.display="none"; el.classList.remove("drag"); setSel(-1);
  if(!it){ $("toast").style.opacity=0; return; }
  const base=name.replace(/\.[^.]+$/,""), ext=name.split(".").pop();
  if(mode==="share") return say(t("sent")+" "+it.l);
  let nn; if(mode==="conv"&&it.k!=="extract") nn=base+"."+it.k; else if(it.k==="extract") nn=base+" (folder)"; else nn=base+" ("+it.l+")."+ext;
  if(!nn.includes("(folder)")&&!KIND[nn.split(".").pop().toLowerCase()]&&mode==="conv") nn=nn; 
  say(t("done")+" "+nn);
}
var tt; function say(s){const e=$("toast"); e.textContent="✓ "+s; e.style.opacity=1; clearTimeout(tt); tt=setTimeout(()=>e.style.opacity=0,3000);}
if(stage){
  $("pick").addEventListener("click",e=>{const b=e.target.closest("button"); if(!b) return; document.querySelectorAll("#pick button").forEach(x=>{x.classList.toggle("on",x===b);x.setAttribute("aria-pressed",x===b);}); $("files").innerHTML=""; const f=fileEl(SAMPLE[b.dataset.k]); f.classList.add("pop"); $("files").appendChild(f); $("empty").style.display="none";});
  $("modes").dataset.base="conv";
  $("modes").addEventListener("click",e=>{const b=e.target.closest("button"); if(!b) return; mode=b.dataset.mode; $("modes").dataset.base=mode; playRefresh();});
  playRefresh();
}
/* contact form: same address and checks as the app's «Report a problem» */
const cf=$("cf");
if(cf){
 const URL_="https://api.formdall.de/api/v1/f/oilh96W60cv9iwq3g5wuMoFxNc7o8rUzoQQ7HCgG"; let busy=false; const st=$("cs");
 const say2=(k,err)=>{st.textContent=t(k); st.dataset.k=k; st.dataset.s=err?"err":"ok";};
 cf.addEventListener("submit",async e=>{
  e.preventDefault(); if(busy) return;
  const f=new FormData(cf); if(f.get("website")){ say2("ct_ok"); cf.reset(); return; }
  const kind=f.get("kind"), msg=(f.get("message")||"").trim(), mail=(f.get("email")||"").trim();
  const okMail=!mail||(mail.length<=254&&/^[^\s@<>"]{1,64}@[^\s@<>"]{1,185}\.[^\s@<>".]{2,}$/.test(mail));
  if(!msg||msg.length>5000||new TextEncoder().encode(msg).length>20000||!okMail||!["problema","idea","altro"].includes(kind)) return say2("ct_bad",1);
  busy=true; $("cb").disabled=true; say2("ct_wait");
  try{
   const r=await fetch(URL_,{method:"POST",headers:{"Content-Type":"application/json",Accept:"application/json"},body:JSON.stringify({tipo:kind,messaggio:"[Sito web] "+msg,...(mail?{email:mail}:{})})});
   let j={}; try{ j=await r.json(); }catch{}
   if(r.status===200&&j.success===true){ say2("ct_ok"); cf.reset(); } else if(r.status===429) say2("ct_busy",1); else say2("ct_err",1);
  }catch{ say2("ct_err",1); }
  busy=false; $("cb").disabled=false;
 });
}
render();
/* ?demo=<kind>: only a button that exists is clicked; the value is compared, never put in a selector */
if(q.get("demo")) [...document.querySelectorAll("#pick button")].find(b=>b.dataset.k===q.get("demo"))?.click();
/* version and date come from the latest GitHub release, never typed by hand */
const v = document.getElementById("ver");
if (v) fetch("https://api.github.com/repos/jackb998/rondelle/releases/latest").then(r => r.ok ? r.json() : Promise.reject())
  .then(j => { v.textContent = " · " + j.tag_name + " · " + new Date(j.published_at).toLocaleDateString(lang); }).catch(() => {});

/* motion: reveal on scroll, quiet hero fade, nav border. All skipped under reduced motion. */
(function(){
  const nav=document.querySelector(".nav"), still=matchMedia("(prefers-reduced-motion: reduce)").matches;
  const onScroll=()=>{ if(nav) nav.classList.toggle("scrolled",scrollY>8); const h=document.querySelector(".hero"); if(h&&!still){const p=Math.min(1,scrollY/Math.max(1,h.offsetHeight)); h.style.setProperty("--p",p); h.style.opacity=1-p*.7; h.style.transform="translateY("+(p*40)+"px) scale("+(1-p*.04)+")";} };
  addEventListener("scroll",onScroll,{passive:true}); onScroll();
  if(still||!("IntersectionObserver" in window)) return;
  const sel=".band h2,.band .lead,.band .sub,.grid3>div,.steps>div,.tabs,.fmt,.also,.play,.doc>*,.page-head>*,.box,.kit,.sw,.cta .btn,.cta .small";
  const els=[...document.querySelectorAll(sel)].filter(e=>!e.closest(".hero"));
  const io=new IntersectionObserver(es=>es.forEach(e=>{ if(e.isIntersecting){ e.target.classList.add("in"); io.unobserve(e.target);} }),{threshold:.12,rootMargin:"0px 0px -6% 0px"});
  els.forEach(e=>{ const sib=[...e.parentElement.children].indexOf(e); e.style.setProperty("--d",Math.min(sib,4)); e.classList.add("rv"); io.observe(e); });
})();
