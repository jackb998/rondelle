/* Rondelle site: texts of the guide and story pages (en, it, fr). Loaded before site.js; missing keys fall back to English. */
const G = {
en:{
 title_guide:"Rondelle · App guide", title_story:"Rondelle · The story",
 n_guide:"App guide", n_story:"Our story",
 gd_h:"App guide", gd_l:"A tour of Rondelle and its Settings, taken from the app itself. What is not confirmed yet is listed at the end.",
 gd_b:"The basics", gd_s:"Settings, one section at a time", gd_c:"Where to make it yours", gd_t:"To be confirmed",
 gd_basics:[
  "<strong>Drag and hold keys.</strong> Drag one or more files from the Finder and hold the keys of a wheel: it appears around the pointer. Drop the file on a slice. Default keys: <kbd>⇧</kbd> Convert, <kbd>⌥⇧</kbd> Tools, <kbd>⌃⇧</kbd> Share. Drop in the centre to cancel.",
  "<strong>Without dragging.</strong> Select files in the Finder, right-click → Services → “Rondelle: Convert…”, “Tools…” or “Share…”. The wheel opens and works with a click, or with ← → ↓ ↑, Return, Tab and Esc.",
  "<strong>Where the result goes.</strong> Next to the original, or in a fixed folder you choose. The first time in a new folder, Rondelle asks for permission.",
  "<strong>Menu bar.</strong> The icon opens a menu with running jobs (each can be cancelled), Undo last conversion, Recent, Pause, How to use…, Settings… (⌘,), Look for updates and Quit."],
 gd_open:"Open Settings from the menu bar icon (Settings…) or with <kbd>⌘ ,</kbd>. A sidebar lists nine sections, with a search box on top. Below, each section is described: what each setting does and where it is.",
 gd_cust:[
  ["Look","Settings → Appearance","Wheel size, segment shape, theme, highlight colour, glass effect, icons, animation, haptics and sound."],
  ["How the wheel works","Settings → Behaviour and Wheel","The keys that open each wheel, which actions each wheel shows and in what order, and the apps on the Share wheel."],
  ["Available tools","Settings → Wheel and Conversions","Tick the actions you use for each kind of file. Set quality, sizes and where files are saved."]],
 gd_panes:[
  {h:"Appearance",w:"Settings → Appearance",i:[
   ["Size","Scales the whole wheel. “Actual size” shows a preview at real size on screen."],
   ["Glass effect (Liquid Glass)","The wheel background lets you see what is behind it. macOS 26 or later. With it on, a slider sets the glass tint; otherwise the same slider sets the background opacity."],
   ["Segment shape","Sharp, Rounded, Extra soft, Chamfered or Pizza slice."],
   ["Wheel theme","Automatic, Dark or Light."],
   ["Highlight","The accent colour of the wheel: nine presets, or any colour you pick."],
   ["Show icons","Icons on the slices, on or off."],
   ["Opening animation","On or off."],
   ["Trackpad tap when moving over items","A small tap on the trackpad, with strength Light, Medium or Firm."],
   ["Click sound when moving over items","A click, with its own volume slider."],
   ["Settings theme","Automatic, Dark or Light, for the Settings window only."]]},
  {h:"Behaviour",w:"Settings → Behaviour",i:[
   ["Keys for the Convert, Tools and Share wheels","Hold one or two of ⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command while dragging. Defaults: ⇧, ⌥⇧ and ⌃⇧. If two wheels share the same keys, only the first opens. ⌘ and ⌥ also change what the Finder does when you drop outside the wheel (move or copy)."],
   ["Change shortcuts…","Opens System Settings → Keyboard, to change the keys of the Services used without dragging."],
   ["Pause Rondelle","Stops the wheel from appearing. Also in the menu bar menu."],
   ["Rondelle language","Same as macOS, or a language you choose. It applies from the next launch; a button restarts the app."],
   ["After converting","Show the result in the Finder. Result card, draggable and undoable. Sound when done. Animation when done: None, Opening ring or Completing circle, with a Try button."],
   ["Open Rondelle at login","Starts the app when you log in."]]},
  {h:"Wheel",w:"Settings → Wheel",i:[
   ["File type and wheel","Pick a kind of file, then Convert, Tools or Share. Each combination has its own list."],
   ["Visible actions and order","Tick the actions to show and drag them to change the order: the first is at the top, the others follow clockwise. A wheel with fewer items is easier to hit. “Reset this wheel” restores the original list."],
   ["Tools wheel style","Ring and panel, Ring only, Panel only or Full wheel. Groups show their variants in a second ring while you hover, in a panel when you drop on the group, or both; Full wheel shows every action with no groups."],
   ["Added apps and services","On the Share wheel: “Add an app…” or add a macOS service, and remove them again. An app with its own share extension (like Telegram) opens the contact picker; the others open with the files on the clipboard, to paste with ⌘V."]]},
  {h:"Conversions",w:"Settings → Conversions",i:[
   ["General: quality and sizes","JPG/HEIC quality. Sizes on the wheel (px): up to four values separated by commas, for example 2560, 1920, 1080, 480. The target size (MB) that “Size…” suggests."],
   ["Where to save files","Next to the original, or in a fixed folder you choose."],
   ["One page per output format","Images (JPG, PNG, HEIC, WebP, TIFF, GIF, BMP), PDF → images, Video (MP4, MOV, M4V, animated GIF), Audio (M4A, MP3, WAV, AIFF) and Spreadsheets (CSV). Depending on the format: keep metadata, size, quality, page resolution, GIF width and frames per second, MP3 quality, CSV separator and UTF-8 mark, bit depth (16-bit CD or 24-bit studio). Each page has “Restore defaults”."],
   ["Restore all default settings","Resets every setting of the app."]]},
  {h:"Formats",w:"Settings → Formats",i:[
   ["Conversion table","Click a source format and a target format, or a cell directly: green if Rondelle can convert, red if not. A third click clears the choice."]]},
  {h:"Privacy",w:"Settings → Privacy",i:[
   ["Guarantees","A list of what the app does not do: no automatic data collection or tracking, no Internet access during conversions, no access to camera, microphone, location, contacts or Photos."],
   ["Look for updates automatically","Once a day a small separate process asks GitHub for the latest version. It sends no files or personal data, but GitHub sees the Mac’s IP address. The update does not install itself."],
   ["Remove the GPS position from converted photos and videos","Applies to every conversion and tool, even with “Keep metadata”."],
   ["Share without location and metadata","From the Share wheel, photos, videos, audio and PDFs leave as copies without GPS location, device, dates and author. The originals do not change."],
   ["Allowed folders","The folders where Rondelle may save converted files: “Allow a folder…” and “Revoke all”."],
   ["History","How many recent jobs to remember (5, 10, 15 or 20) and “Clear history”."]]},
  {h:"About, Support and Help",w:"Settings → About, Support Rondelle, Help and contact",i:[
   ["About","Version, licence and a button to this website."],
   ["Support Rondelle","A link to Buy Me a Coffee."],
   ["Help and contact","Watch the tutorial again, and report a problem or send an idea."]]}],
 gd_todo:[
  "The unit of the Size slider (the code allows steps from 0.6 to 1.6 in 0.05 steps).",
  "The complete list of tool groups on the Tools wheel, for each kind of file.",
  "What exactly “draggable” means for the result card: what can be dragged out of it."],
 st_h:"Our story",
 st_p:[
  "Rondelle began with a very simple idea. Until now, changing the format of a file meant picking one of three habits. You look for a dedicated app that does almost everything, but feels dated and whose name you never remember when you need it. Or you head to a random website and convert the file there. Or you ask an AI. Each of them costs time, and each can mean handing personal or private information to services you would rather not share it with.",
  "After many attempts with Mac automation, Rondelle was born from the wish to put everything in one app, always within reach, and to open it with two very simple actions: a click and a drag.",
  "Converters already exist, and nobody should pretend otherwise. Rondelle makes its own choices. It is easy to use. It keeps everything on your Mac. It is fully customizable, and it is designed to be quick to reach and pleasant to look at. (The App guide shows where and how to make it yours.)",
  "It was made for people who need only a few tools in one place, shaped to their taste both in looks and in feel, down to the gesture that opens the wheel. And just as much for people who use many tools through the day and want them all together.",
  "Privacy stays essential. Not only because everything remains on the computer and nothing is shared, but because some tools, such as removing metadata, exist precisely so that you can share a file easily and safely. In a world that moves fast, where our information is precious to us and to others, the fewer files we share, the less others know about us."],
 st_n:"A word on the name",
 st_np:[
  "In Italian, <i>rondelle</i> is the plural of <i>rondella</i>: the small component used in manual work. A washer is a small disc with a hole that sits between the head of a screw (or a nut) and the surface being tightened.",
  "The idea fits the app. Rondelle sits between the person and the final result, and it is the part that lets you finish the job and be sure it holds. The word also echoes French, where <i>rondelle</i> means exactly the same thing, in the singular."],
 st_c:"Closing", st_cp:"If you like the project, you can chip in with a coffee.", st_cb:"Buy me a coffee"
},
it:{
 title_guide:"Rondelle · Guida all’app", title_story:"Rondelle · La storia",
 n_guide:"Guida all’app", n_story:"La nostra storia",
 gd_h:"Guida all’app", gd_l:"Un giro di Rondelle e delle sue Impostazioni, ricavato dall’app stessa. Ciò che non è ancora confermato è elencato alla fine.",
 gd_b:"Le basi", gd_s:"Le Impostazioni, una sezione alla volta", gd_c:"Dove renderla tua", gd_t:"Da confermare",
 gd_basics:[
  "<strong>Trascina e tieni premuti i tasti.</strong> Trascina uno o più file dal Finder e tieni premuti i tasti di una ruota: compare attorno al puntatore. Rilascia il file su uno spicchio. Tasti predefiniti: <kbd>⇧</kbd> Converti, <kbd>⌥⇧</kbd> Strumenti, <kbd>⌃⇧</kbd> Condividi. Rilascia al centro per annullare.",
  "<strong>Senza trascinare.</strong> Seleziona i file nel Finder, clic destro → Servizi → «Rondelle: Converti…», «Strumenti…» o «Condividi…». La ruota si apre e funziona con un clic, oppure con ← → ↓ ↑, Invio, Tab ed Esc.",
  "<strong>Dove va il risultato.</strong> Accanto all’originale, oppure in una cartella fissa che scegli. La prima volta in una cartella nuova Rondelle chiede il permesso.",
  "<strong>Barra dei menu.</strong> L’icona apre un menu con i lavori in corso (ognuno si può annullare), Annulla ultima conversione, Recenti, Metti in pausa, Come si usa…, Impostazioni… (⌘,), Cerca aggiornamenti ed Esci."],
 gd_open:"Apri le Impostazioni dall’icona nella barra dei menu (Impostazioni…) o con <kbd>⌘ ,</kbd>. Una barra laterale elenca nove sezioni, con un campo di ricerca in alto. Qui sotto trovi ogni sezione: cosa fa ogni impostazione e dove si trova.",
 gd_cust:[
  ["Aspetto","Impostazioni → Aspetto","Dimensione della ruota, forma degli spicchi, tema, colore di evidenziazione, effetto vetro, icone, animazione, tocco e suono."],
  ["Come funziona la ruota","Impostazioni → Comportamento e Ruota","I tasti che aprono ogni ruota, quali azioni mostra ciascuna e in che ordine, e le app della ruota Condividi."],
  ["Strumenti disponibili","Impostazioni → Ruota e Conversioni","Spunta le azioni che usi per ogni tipo di file. Imposta qualità, dimensioni e dove salvare i file."]],
 gd_panes:[
  {h:"Aspetto",w:"Impostazioni → Aspetto",i:[
   ["Dimensione","Ingrandisce o riduce tutta la ruota. «Grandezza reale» mostra un’anteprima a dimensione reale sullo schermo."],
   ["Effetto vetro (Liquid Glass)","Lo sfondo della ruota lascia vedere ciò che c’è dietro. Da macOS 26. Se è attivo, un cursore regola la tinta del vetro; altrimenti lo stesso cursore regola l’opacità dello sfondo."],
   ["Forma degli spicchi","Netta, Tonda, Molto morbida, Smussata o Fetta di pizza."],
   ["Tema della ruota","Automatico, Scuro o Chiaro."],
   ["Evidenziazione","Il colore d’accento della ruota: nove colori già pronti, o un colore a scelta."],
   ["Mostra icone","Le icone sugli spicchi, attive o no."],
   ["Animazione di apertura","Attiva o no."],
   ["Tocco sul trackpad passando sulle voci","Un piccolo tocco sul trackpad, con intensità Leggero, Medio o Deciso."],
   ["Clic sonoro passando sulle voci","Un clic, con un cursore del volume."],
   ["Tema delle impostazioni","Automatico, Scuro o Chiaro, solo per la finestra delle Impostazioni."]]},
  {h:"Comportamento",w:"Impostazioni → Comportamento",i:[
   ["Tasti delle ruote Converti, Strumenti e Condividi","Tieni premuti uno o due tra ⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command mentre trascini. Predefiniti: ⇧, ⌥⇧ e ⌃⇧. Se due ruote hanno gli stessi tasti, si apre solo la prima. ⌘ e ⌥ cambiano anche ciò che fa il Finder se rilasci fuori dalla ruota (sposta o copia)."],
   ["Cambia le scorciatoie…","Apre Impostazioni di Sistema → Tastiera, per cambiare i tasti dei Servizi usati senza trascinare."],
   ["Metti in pausa Rondelle","Impedisce alla ruota di comparire. Si trova anche nel menu della barra."],
   ["Lingua di Rondelle","Come macOS, o una lingua a scelta. Vale dall’avvio successivo; un pulsante riavvia l’app."],
   ["Dopo la conversione","Mostra il risultato nel Finder. Scheda con il risultato, trascinabile e annullabile. Suono al termine. Animazione al termine: Nessuna, Anello che si apre o Cerchio che si completa, con un pulsante Prova."],
   ["Avvia Rondelle al login","Apre l’app quando accedi."]]},
  {h:"Ruota",w:"Impostazioni → Ruota",i:[
   ["Tipo di file e ruota","Scegli un tipo di file, poi Converti, Strumenti o Condividi. Ogni combinazione ha il suo elenco."],
   ["Azioni visibili e ordine","Spunta le azioni da mostrare e trascinale per cambiare l’ordine: la prima è in alto, le altre seguono in senso orario. Una ruota con meno voci è più facile da centrare. «Ripristina questa ruota» riporta l’elenco originale."],
   ["Stile della ruota Strumenti","Anello e pannello, Solo anello, Solo pannello o Ruota completa. I gruppi mostrano le varianti in un secondo anello mentre passi sopra, in un pannello quando rilasci sul gruppo, o entrambi; Ruota completa mostra ogni azione senza gruppi."],
   ["App e servizi aggiunti","Sulla ruota Condividi: «Aggiungi un’app…» o un servizio di macOS, e puoi rimuoverli. Un’app con la sua estensione di condivisione (come Telegram) apre la scelta del contatto; le altre si aprono con i file negli appunti, da incollare con ⌘V."]]},
  {h:"Conversioni",w:"Impostazioni → Conversioni",i:[
   ["Generale: qualità e dimensioni","Qualità JPG/HEIC. Dimensioni nella ruota (px): fino a quattro valori separati da virgole, per esempio 2560, 1920, 1080, 480. Il peso di destinazione (MB) che propone «Peso…»."],
   ["Dove salvare i file","Accanto all’originale, oppure in una cartella fissa che scegli."],
   ["Una pagina per ogni formato di arrivo","Immagini (JPG, PNG, HEIC, WebP, TIFF, GIF, BMP), PDF → immagini, Video (MP4, MOV, M4V, GIF animata), Audio (M4A, MP3, WAV, AIFF) e Fogli di calcolo (CSV). A seconda del formato: mantieni i metadati, dimensioni, qualità, risoluzione delle pagine, larghezza e fotogrammi al secondo delle GIF, qualità MP3, separatore CSV e segno UTF-8, profondità (16 bit CD o 24 bit studio). Ogni pagina ha «Ripristina i valori predefiniti»."],
   ["Ripristina tutte le impostazioni predefinite","Riporta ogni impostazione dell’app ai valori iniziali."]]},
  {h:"Formati",w:"Impostazioni → Formati",i:[
   ["Tabella delle conversioni","Clicca un formato di partenza e uno di arrivo, o direttamente una casella: verde se Rondelle sa convertire, rosso se no. Un terzo clic azzera."]]},
  {h:"Privacy",w:"Impostazioni → Privacy",i:[
   ["Garanzie","Un elenco di ciò che l’app non fa: nessuna raccolta di dati né tracciamento automatici, nessun accesso a Internet durante le conversioni, nessun accesso a fotocamera, microfono, posizione, contatti o Foto."],
   ["Cerca aggiornamenti automaticamente","Una volta al giorno un piccolo processo separato chiede a GitHub qual è l’ultima versione. Non invia file né dati personali, ma GitHub vede l’indirizzo IP del Mac. L’aggiornamento non si installa da solo."],
   ["Togli la posizione GPS da foto e video convertiti","Vale per ogni conversione e strumento, anche con «Mantieni i metadati»."],
   ["Condividi senza posizione e metadati","Dalla ruota Condividi, foto, video, audio e PDF partono come copie senza posizione GPS, dispositivo, date e autore. Gli originali non cambiano."],
   ["Cartelle autorizzate","Le cartelle in cui Rondelle può salvare i file convertiti: «Autorizza una cartella…» e «Revoca tutte»."],
   ["Cronologia","Quanti lavori recenti ricordare (5, 10, 15 o 20) e «Svuota cronologia»."]]},
  {h:"Informazioni, Sostieni Rondelle e Aiuto",w:"Impostazioni → Informazioni, Sostieni Rondelle, Aiuto e contatti",i:[
   ["Informazioni","Versione, licenza e un pulsante per questo sito."],
   ["Sostieni Rondelle","Un link a Buy Me a Coffee."],
   ["Aiuto e contatti","Rivedi il tutorial, segnala un problema o manda un’idea."]]}],
 gd_todo:[
  "L’unità del cursore Dimensione (il codice ammette valori da 0,6 a 1,6 a passi di 0,05).",
  "L’elenco completo dei gruppi di strumenti nella ruota Strumenti, per ogni tipo di file.",
  "Cosa significa esattamente «trascinabile» per la scheda del risultato: cosa si può trascinare fuori."],
 st_h:"La nostra storia",
 st_p:[
  "Rondelle nasce da un’idea molto semplice. Finora, cambiare il formato di un file voleva dire scegliere una di tre abitudini. Cercare un’app dedicata che fa quasi tutto, ma ha un’aria datata e di cui non ricordiamo mai il nome quando serve. Oppure finire su un sito a caso e convertire il file lì. Oppure chiedere a un’AI. In tutti e tre i casi si perde tempo, e si rischia di consegnare informazioni personali o private a servizi con cui non vorremmo condividerle.",
  "Dopo molti tentativi con l’automazione del Mac, Rondelle nasce dal desiderio di mettere tutto in un’unica app, sempre a portata di mano, e di aprirla con due azioni semplicissime: un clic e un trascinamento.",
  "I convertitori esistono già, e non c’è motivo di negarlo. Rondelle fa le sue scelte. È facile da usare. Tiene tutto sul tuo Mac. È completamente personalizzabile, ed è pensata per essere rapida da raggiungere e piacevole da guardare. (La Guida all’app mostra dove e come renderla tua.)",
  "È pensata per chi ha bisogno di pochi strumenti in un unico posto, su misura per i propri gusti sia nell’aspetto sia nel modo di usarla, fino al gesto che apre la ruota. E altrettanto per chi usa molti strumenti nel corso della giornata e li vuole tutti insieme.",
  "La privacy resta essenziale. Non solo perché tutto rimane sul computer e nulla viene condiviso, ma perché alcuni strumenti, come la rimozione dei metadati, esistono proprio per condividere un file in modo semplice e sicuro. In un mondo che corre, in cui le nostre informazioni sono preziose per noi e per gli altri, meno file condividiamo, meno gli altri sapranno di noi."],
 st_n:"Due parole sul nome",
 st_np:[
  "In italiano <i>rondelle</i> è il plurale di <i>rondella</i>: il piccolo componente che si usa nei lavori manuali. Una rondella è un piccolo disco forato che si inserisce tra la testa di una vite (o un dado) e la superficie da serrare.",
  "L’idea si adatta all’app. Rondelle sta in mezzo tra la persona e il risultato finale, ed è la parte che permette di concludere il lavoro e di essere sicuri che regga. La parola richiama anche il francese, dove <i>rondelle</i> significa esattamente la stessa cosa, al singolare."],
 st_c:"Per chiudere", st_cp:"Se il progetto ti piace, puoi contribuire con un caffè.", st_cb:"Offrimi un caffè"
},
fr:{
 title_guide:"Rondelle · Guide de l’app", title_story:"Rondelle · L’histoire",
 n_guide:"Guide de l’app", n_story:"Notre histoire",
 gd_h:"Guide de l’app", gd_l:"Un tour de Rondelle et de ses Réglages, tiré de l’app elle-même. Ce qui n’est pas encore confirmé figure à la fin.",
 gd_b:"Les bases", gd_s:"Les Réglages, section par section", gd_c:"Où la faire vôtre", gd_t:"À confirmer",
 gd_basics:[
  "<strong>Glissez et maintenez les touches.</strong> Faites glisser un ou plusieurs fichiers depuis le Finder et maintenez les touches d’une roue : elle apparaît autour du pointeur. Déposez le fichier sur une part. Touches par défaut : <kbd>⇧</kbd> Convertir, <kbd>⌥⇧</kbd> Outils, <kbd>⌃⇧</kbd> Partager. Déposez au centre pour annuler.",
  "<strong>Sans glisser.</strong> Sélectionnez des fichiers dans le Finder, clic droit → Services → « Rondelle : Convertir… », « Outils… » ou « Partager… ». La roue s’ouvre et fonctionne d’un clic, ou avec ← → ↓ ↑, Retour, Tab et Échap.",
  "<strong>Où va le résultat.</strong> À côté de l’original, ou dans un dossier fixe que vous choisissez. La première fois dans un nouveau dossier, Rondelle demande l’autorisation.",
  "<strong>Barre des menus.</strong> L’icône ouvre un menu avec les tâches en cours (chacune peut être annulée), Annuler la dernière conversion, Récents, Mettre en pause, Comment ça marche…, Réglages… (⌘,), Rechercher des mises à jour et Quitter."],
 gd_open:"Ouvrez les Réglages depuis l’icône de la barre des menus (Réglages…) ou avec <kbd>⌘ ,</kbd>. Une barre latérale liste neuf sections, avec un champ de recherche en haut. Ci-dessous, chaque section : ce que fait chaque réglage et où il se trouve.",
 gd_cust:[
  ["Apparence","Réglages → Apparence","Taille de la roue, forme des parts, thème, couleur de surbrillance, effet verre, icônes, animation, retour tactile et son."],
  ["Fonctionnement de la roue","Réglages → Comportement et Roue","Les touches qui ouvrent chaque roue, les actions affichées par chacune et leur ordre, et les apps de la roue Partager."],
  ["Outils disponibles","Réglages → Roue et Conversions","Cochez les actions que vous utilisez pour chaque type de fichier. Réglez la qualité, les tailles et le dossier d’enregistrement."]],
 gd_panes:[
  {h:"Apparence",w:"Réglages → Apparence",i:[
   ["Taille","Agrandit ou réduit toute la roue. « Taille réelle » affiche un aperçu à la taille réelle à l’écran."],
   ["Effet verre (Liquid Glass)","Le fond de la roue laisse voir ce qui se trouve derrière. À partir de macOS 26. Activé, un curseur règle la teinte du verre ; sinon le même curseur règle l’opacité du fond."],
   ["Forme des parts","Nette, Arrondie, Très douce, Biseautée ou Part de pizza."],
   ["Thème de la roue","Automatique, Sombre ou Clair."],
   ["Surbrillance","La couleur d’accent de la roue : neuf couleurs prêtes, ou la couleur de votre choix."],
   ["Afficher les icônes","Les icônes sur les parts, activées ou non."],
   ["Animation d’ouverture","Activée ou non."],
   ["Retour tactile du trackpad en survolant les éléments","Un léger toucher sur le trackpad, d’intensité Léger, Moyen ou Ferme."],
   ["Clic sonore en survolant les éléments","Un clic, avec un curseur de volume."],
   ["Thème des réglages","Automatique, Sombre ou Clair, pour la fenêtre des Réglages seulement."]]},
  {h:"Comportement",w:"Réglages → Comportement",i:[
   ["Touches des roues Convertir, Outils et Partager","Maintenez une ou deux touches parmi ⌃ Contrôle, ⌥ Option, ⇧ Majuscule, ⌘ Commande pendant le glissement. Par défaut : ⇧, ⌥⇧ et ⌃⇧. Si deux roues ont les mêmes touches, seule la première s’ouvre. ⌘ et ⌥ changent aussi ce que fait le Finder si vous déposez hors de la roue (déplacer ou copier)."],
   ["Changer les raccourcis…","Ouvre Réglages Système → Clavier, pour changer les touches des Services utilisés sans glisser."],
   ["Mettre Rondelle en pause","Empêche la roue d’apparaître. Aussi dans le menu de la barre."],
   ["Langue de Rondelle","Comme macOS, ou une langue de votre choix. Elle s’applique au prochain lancement ; un bouton relance l’app."],
   ["Après la conversion","Afficher le résultat dans le Finder. Fiche du résultat, déplaçable et annulable. Son à la fin. Animation à la fin : Aucune, Anneau qui s’ouvre ou Cercle qui se complète, avec un bouton Essayer."],
   ["Ouvrir Rondelle à la connexion","Lance l’app quand vous ouvrez votre session."]]},
  {h:"Roue",w:"Réglages → Roue",i:[
   ["Type de fichier et roue","Choisissez un type de fichier, puis Convertir, Outils ou Partager. Chaque combinaison a sa propre liste."],
   ["Actions visibles et ordre","Cochez les actions à afficher et faites-les glisser pour changer l’ordre : la première est en haut, les autres suivent dans le sens horaire. Une roue avec moins d’éléments est plus facile à viser. « Réinitialiser cette roue » rétablit la liste d’origine."],
   ["Style de la roue Outils","Anneau et panneau, Anneau seul, Panneau seul ou Roue complète. Les groupes montrent leurs variantes dans un second anneau au survol, dans un panneau quand vous déposez sur le groupe, ou les deux ; Roue complète affiche chaque action sans groupes."],
   ["Apps et services ajoutés","Sur la roue Partager : « Ajouter une app… » ou un service macOS, que vous pouvez retirer. Une app avec sa propre extension de partage (comme Telegram) ouvre le choix du contact ; les autres s’ouvrent avec les fichiers dans le presse-papiers, à coller avec ⌘V."]]},
  {h:"Conversions",w:"Réglages → Conversions",i:[
   ["Général : qualité et tailles","Qualité JPG/HEIC. Tailles dans la roue (px) : jusqu’à quatre valeurs séparées par des virgules, par exemple 2560, 1920, 1080, 480. Le poids cible (Mo) que propose « Poids… »."],
   ["Où enregistrer les fichiers","À côté de l’original, ou dans un dossier fixe que vous choisissez."],
   ["Une page par format de sortie","Images (JPG, PNG, HEIC, WebP, TIFF, GIF, BMP), PDF → images, Vidéo (MP4, MOV, M4V, GIF animé), Audio (M4A, MP3, WAV, AIFF) et Tableurs (CSV). Selon le format : conserver les métadonnées, taille, qualité, résolution des pages, largeur et images par seconde des GIF, qualité MP3, séparateur CSV et marque UTF-8, profondeur (16 bits CD ou 24 bits studio). Chaque page a « Rétablir les valeurs par défaut »."],
   ["Rétablir tous les réglages par défaut","Remet chaque réglage de l’app à sa valeur initiale."]]},
  {h:"Formats",w:"Réglages → Formats",i:[
   ["Tableau des conversions","Cliquez un format de départ et un format d’arrivée, ou directement une case : vert si Rondelle sait convertir, rouge sinon. Un troisième clic efface le choix."]]},
  {h:"Confidentialité",w:"Réglages → Confidentialité",i:[
   ["Garanties","Une liste de ce que l’app ne fait pas : aucune collecte de données ni suivi automatiques, aucun accès à Internet pendant les conversions, aucun accès à la caméra, au micro, à la position, aux contacts ou à Photos."],
   ["Rechercher les mises à jour automatiquement","Une fois par jour, un petit processus séparé demande à GitHub quelle est la dernière version. Il n’envoie ni fichiers ni données personnelles, mais GitHub voit l’adresse IP du Mac. La mise à jour ne s’installe pas toute seule."],
   ["Retirer la position GPS des photos et vidéos converties","S’applique à chaque conversion et outil, même avec « Conserver les métadonnées »."],
   ["Partager sans position ni métadonnées","Depuis la roue Partager, photos, vidéos, audio et PDF partent en copies sans position GPS, appareil, dates ni auteur. Les originaux ne changent pas."],
   ["Dossiers autorisés","Les dossiers où Rondelle peut enregistrer les fichiers convertis : « Autoriser un dossier… » et « Tout révoquer »."],
   ["Historique","Combien de tâches récentes retenir (5, 10, 15 ou 20) et « Effacer l’historique »."]]},
  {h:"À propos, Soutenir et Aide",w:"Réglages → À propos, Soutenir Rondelle, Aide et contact",i:[
   ["À propos","Version, licence et un bouton vers ce site."],
   ["Soutenir Rondelle","Un lien vers Buy Me a Coffee."],
   ["Aide et contact","Revoir le tutoriel, signaler un problème ou envoyer une idée."]]}],
 gd_todo:[
  "L’unité du curseur Taille (le code admet des valeurs de 0,6 à 1,6 par pas de 0,05).",
  "La liste complète des groupes d’outils de la roue Outils, pour chaque type de fichier.",
  "Ce que signifie exactement « déplaçable » pour la fiche du résultat : ce que l’on peut en faire glisser."],
 st_h:"Notre histoire",
 st_p:[
  "Rondelle est née d’une idée très simple. Jusqu’ici, changer le format d’un fichier revenait à choisir parmi trois habitudes. Chercher une app dédiée qui fait presque tout, mais d’allure datée et dont on ne retrouve jamais le nom au moment voulu. Ou aller sur un site au hasard et y convertir le fichier. Ou demander à une IA. Dans les trois cas, on perd du temps, et on risque de confier des informations personnelles ou privées à des services avec lesquels on ne voudrait pas les partager.",
  "Après de nombreux essais avec l’automatisation du Mac, Rondelle est née du désir de tout réunir dans une seule app, toujours à portée de main, et de l’ouvrir en deux gestes très simples : un clic et un glissement.",
  "Les convertisseurs existent déjà, et il n’y a aucune raison de le nier. Rondelle fait ses propres choix. Elle est facile à utiliser. Elle garde tout sur votre Mac. Elle est entièrement personnalisable, et conçue pour être rapide d’accès et agréable à regarder. (Le Guide de l’app montre où et comment la faire vôtre.)",
  "Elle est pensée pour ceux qui n’ont besoin que de quelques outils au même endroit, à leur goût autant par l’apparence que par la façon de s’en servir, jusqu’au geste qui ouvre la roue. Et tout autant pour ceux qui utilisent beaucoup d’outils au fil de la journée et les veulent tous ensemble.",
  "La confidentialité reste essentielle. Pas seulement parce que tout reste sur l’ordinateur et que rien n’est partagé, mais parce que certains outils, comme la suppression des métadonnées, existent justement pour partager un fichier simplement et en sécurité. Dans un monde qui va vite, où nos informations sont précieuses pour nous comme pour les autres, moins nous partageons de fichiers, moins les autres en sauront sur nous."],
 st_n:"Un mot sur le nom",
 st_np:[
  "En italien, <i>rondelle</i> est le pluriel de <i>rondella</i> : le petit composant utilisé dans les travaux manuels. Une rondelle est un petit disque percé qui se glisse entre la tête d’une vis (ou un écrou) et la surface à serrer.",
  "L’idée convient à l’app. Rondelle se place entre la personne et le résultat final, et c’est la pièce qui permet de terminer le travail et d’être sûr qu’il tienne. Le mot rappelle aussi le français, où <i>rondelle</i> signifie exactement la même chose, au singulier."],
 st_c:"Pour finir", st_cp:"Si le projet vous plaît, vous pouvez contribuer avec un café.", st_cb:"Offrez-moi un café"
}};
function guideHTML() {
  const g = G[lang], e = G.en, x = k => g[k] ?? e[k];
  const items = a => a.map(i => `<dt>${i[0]}</dt><dd>${i[1]}</dd>`).join("");
  return `<h2>${x("gd_b")}</h2><ul class="rules">${x("gd_basics").map(s => `<li>${s}</li>`).join("")}</ul>
<p>${x("gd_open")}</p>
<section class="cust" id="personalise"><h2>${x("gd_c")}</h2><div class="cust3">${x("gd_cust").map(c => `<div><h3>${c[0]}</h3><span class="where">${c[1]}</span><p>${c[2]}</p></div>`).join("")}</div></section>
<h2>${x("gd_s")}</h2>${x("gd_panes").map(p => `<h3 class="pane">${p.h}</h3><p class="where">${p.w}</p><dl class="set">${items(p.i)}</dl>`).join("")}
<h2>${x("gd_t")}</h2><ul class="rules">${x("gd_todo").map(s => `<li>${s}</li>`).join("")}</ul>`;
}
function storyHTML() {
  const g = G[lang], e = G.en, x = k => g[k] ?? e[k];
  return `${x("st_p").map(s => `<p>${s}</p>`).join("")}<h2>${x("st_n")}</h2>${x("st_np").map(s => `<p>${s}</p>`).join("")}<h2>${x("st_c")}</h2><p>${x("st_cp")}</p><p><a class="btn" href="https://buymeacoffee.com/jackb998" target="_blank" rel="noopener noreferrer">${x("st_cb")}</a></p>`;
}
