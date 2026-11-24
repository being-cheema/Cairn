// Plain, easy-to-type words for a passphrase: four to seven letters, nothing
// rude, nothing that sounds like another word on the list. Bundled: no
// network, no system dictionary. `PasswordGenerator` counts them to say how
// strong a phrase is, so the number may change without anything else changing.

enum PasswordWords {
    static let list: [String] = """
    able acid acorn actor adapt adult agent agree ahead alarm album alert alley alpha amber ample angel angle ankle apple apron arena argue arise armor array arrow atlas audio avoid awake award
    bacon badge baker basic basin batch beach beard beast begin bench berry bike birth black blade blank blast blaze blend blind block bloom board boost booth bound brain brake brand brave bread brick bride brief bring broad brook broom brown brush buddy build bunch burst
    cabin cable cache calm camel canal candy canoe canvas carol carry carve cedar chain chair chalk charm chart chase cheap check cheer chess chief child chill choir chord churn cider cigar civic claim clash class clean clear clerk click cliff climb clock cloth cloud clover clown coach coast cobra cocoa comet coral couch cover craft crane crash crawl cream creek crest crisp cross crowd crown crumb crush cubic curve cycle
    daily daisy dance dandy dawn decay delta denim depth derby desert desk diary diner disco ditch dizzy dodge donor doubt dough dozen draft drain drama dream dress drift drill drink drive drum dryer dusty
    eagle early earth easel eight elbow elder elect elite ember empty enact enjoy enter entry equal error essay event every exact exile extra
    fable faint fairy faith false fancy farm fault feast fence ferry fever fiber field fiery fifth fifty final finch first fjord flame flash flask fleet flint float flock flood floor flour fluid flute focus foggy folk force forge forth forum frame frank fresh friar frost fruit fudge funny
    gadget gaily galaxy gamma garden garlic gauge gecko ghost giant gift giddy given glade glass gleam glide globe gloom glory glove glue goose grace grade grain grand grant grape graph grass gravy great green greet grid grill grind groom group grove grown guard guess guest guide guild
    habit hairy half hammer hand handy happy harbor hardy harp haste hatch haven hazel heart hedge hello hence heron hiker hinge hobby holly honey honor hoped horse hotel house hover human humor hurry husky hymn
    icing ideal igloo image inbox index indoor inner input irony ivory
    jacket jelly jewel joint jolly judge juice jumbo jumpy junior
    kayak keen kernel kettle kiosk kitten knack knead knee kneel knife knit knob knock koala
    label lace ladder lady lagoon lake lamb lamp lance large laser latch later laugh lava layer leaf learn lease ledge lemon level lever light lilac limit linen lion liter lively llama lobby local lodge logic lone loose lotus loyal lucky lunar lunch lyric
    magic magnet maize major maple march marsh mason match meadow medal melon mercy merit metal meter might mild mimic mine minor mint mirth mist mocha model moist money month moose moral motor mount mouse mouth movie much mural music
    nacho naive navy needle nerve never newly night noble noise north notch novel nurse nylon
    oasis ocean offer often olive onion opera orbit order organ otter ounce outer owner oxide
    paddle paint panda panel paper parade park party pasta patch pause peace peach pearl pedal penny perch petal phase phone photo piano pick piece pilot pinch pine pitch pixel pizza place plain plane plant plate plaza plenty plot plum plush poem point polar pond pony pool poppy porch pouch pound power prank press price pride prime print prism prize proof proud pulse pupil puppy purse
    quail quart queen quest quick quiet quilt quirk quota quote
    rabbit radar radio raft rain raise rally ranch range rapid raven razor reach react ready realm rebel reef relax relay reply rhyme ridge rifle right rigid ring risky rival river roast robin robot rocky rodeo roman roof rope rose rough round route royal ruby rugby rural
    sadly safe sage sail salad salmon salon sandy sauce scale scarf scene scent scout screw seal season seed sense seven shade shaft shake shape share shark sharp sheep shelf shell shift shine shiny shirt shore short shrub siege sight silk silly since siren sixth skate sketch skill skirt skull slate sleep slice slide slope small smart smile smoke snack snail snake snowy soap solar solid sonic sound south space spare spark speak speed spell spice spike spine spoon sport spray spring squad stable staff stage stair stamp stand star start state steam steel steep stem stick still stone stool storm story stove straw strip study stuff style sugar suite sunny super surf swamp swan sweet swift swing sword syrup
    table tacit talent tango tape tarot taste teach tempo tenor tense tenth tent thank theme thick thing think third thorn three throw thumb tidal tiger tight timer tiny tip toast today token tonic tooth topaz torch total touch tower toy trace track trade trail train trait tramp trash treat tree trend trial tribe trick trout truck truly trunk trust truth tulip tuna tunic turbo twice twist
    ultra uncle under union unity until upper urban usual utter
    vague valid valley value valve vapor vault velvet venue verse vessel video vigor villa vine vinyl viola viper visit visor vital vivid vocal voice voter vowel
    wafer wagon waist waltz water weave wedge weigh weird whale wheat wheel whisk white whole widow width wield windy wing wiser witch wizard woman wonder wood world worth wrist writer
    yacht yearly yeast yield young youth
    zebra zesty zinc zippy zone
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
}
