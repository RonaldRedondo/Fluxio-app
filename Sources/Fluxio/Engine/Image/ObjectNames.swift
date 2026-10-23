import Foundation

/// Nombres en español para las capas de animales del PSD, a partir de las etiquetas en inglés del
/// reconocimiento de imágenes de macOS (Vision), y las etiquetas que indican una persona.
enum ObjectNames {
    /// Etiquetas que indican que es una persona.
    static let people: Set<String> = ["people", "adult", "child", "baby", "teen", "bride", "groom", "bridesmaid",
                                      "crowd", "acrobat", "ballet_dancer", "clown", "cowboy_hat", "santa_claus"]

    static let animals: [String: String] = [
        "animal": "Animal", "mammal": "Animal",
        // Perros y gatos (las razas se quedan en "Perro": es más útil y no se equivoca)
        "dog": "Perro", "canine": "Perro", "australian_shepherd": "Perro", "basenji": "Perro", "basset": "Perro",
        "beagle": "Perro", "bernese_mountain": "Perro", "bichon": "Perro", "bulldog": "Perro", "chihuahua": "Perro",
        "collie": "Perro", "corgi": "Perro", "dachshund": "Perro", "dalmatian": "Perro", "doberman": "Perro",
        "german_shepherd": "Perro", "greyhound": "Perro", "hound": "Perro", "husky": "Perro",
        "irish_wolfhound": "Perro", "jack_russell_terrier": "Perro", "malamute": "Perro", "malinois": "Perro",
        "mastiff": "Perro", "newfoundland": "Perro", "pitbull": "Perro", "pomeranian": "Perro", "poodle": "Perro",
        "pug": "Perro", "retriever": "Perro", "ridgeback": "Perro", "rottweiler": "Perro", "saint_bernard": "Perro",
        "schnauzer": "Perro", "setter": "Perro", "sheepdog": "Perro", "spaniel": "Perro", "terrier": "Perro",
        "vizsla": "Perro", "weimaraner": "Perro",
        "cat": "Gato", "adult_cat": "Gato", "kitten": "Gato", "feline": "Felino",
        // Mamíferos
        "bear": "Oso", "bison": "Bisonte", "boar": "Jabalí", "bobcat": "Lince", "camel": "Camello",
        "cheetah": "Guepardo", "chinchilla": "Chinchilla", "cougar": "Puma", "cow": "Vaca", "coyote_wolf": "Lobo",
        "deer": "Ciervo", "donkey": "Burro", "elephant": "Elefante", "elk": "Alce", "ferret": "Hurón",
        "fox": "Zorro", "gerbil": "Jerbo", "giraffe": "Jirafa", "goat": "Cabra", "hamster": "Hámster",
        "hedgehog": "Erizo", "hippopotamus": "Hipopótamo", "horse": "Caballo", "hyena": "Hiena",
        "kangaroo": "Canguro", "koala": "Koala", "lemur": "Lémur", "leopard": "Leopardo", "lion": "León",
        "llama": "Llama", "lynx": "Lince", "marsupial": "Marsupial", "moose": "Alce", "otter": "Nutria",
        "panda": "Panda", "pig": "Cerdo", "porcupine": "Puercoespín", "prairie_dog": "Perrito de las praderas",
        "rabbit": "Conejo", "raccoon": "Mapache", "rat": "Rata", "rhinoceros": "Rinoceronte", "rodent": "Roedor",
        "sheep": "Oveja", "skunk": "Mofeta", "squirrel": "Ardilla", "tiger": "Tigre", "ungulates": "Animal",
        "zebra": "Cebra", "walrus": "Morsa", "seal": "Foca", "sealion": "León marino", "whale": "Ballena",
        "dolphin": "Delfín", "cetacean": "Cetáceo",
        // Aves
        "bird": "Pájaro", "cockatoo": "Cacatúa", "dove": "Paloma", "eagle": "Águila", "flamingo": "Flamenco",
        "gull": "Gaviota", "heron": "Garza", "hummingbird": "Colibrí", "ostrich": "Avestruz", "owl": "Búho",
        "parakeet": "Periquito", "parrot": "Loro", "peacock": "Pavo real", "pelican": "Pelícano",
        "penguin": "Pingüino", "peregrine": "Halcón", "pigeon": "Paloma", "poultry": "Ave de corral",
        "puffin": "Frailecillo", "raptor": "Ave rapaz", "raven": "Cuervo", "sandpiper": "Ave", "sparrow": "Gorrión",
        "stork": "Cigüeña", "swan": "Cisne", "toucan": "Tucán", "vulture": "Buitre", "woodpecker": "Pájaro carpintero",
        // Reptiles y anfibios
        "reptile": "Reptil", "alligator_crocodile": "Cocodrilo", "chameleon": "Camaleón", "gecko": "Geco",
        "iguana": "Iguana", "lizard": "Lagarto", "monitor_lizard": "Varano", "snake": "Serpiente",
        "snake_other": "Serpiente", "python": "Pitón", "rattlesnake": "Serpiente de cascabel", "tortoise": "Tortuga",
        "turtle": "Tortuga", "frog": "Rana", "toad": "Sapo", "dinosaur": "Dinosaurio",
        // Peces y animales marinos
        "fish": "Pez", "angelfish": "Pez ángel", "clownfish": "Pez payaso", "goldfish": "Pez dorado",
        "guppy": "Pez", "koi": "Carpa koi", "lionfish": "Pez león", "puffer_fish": "Pez globo", "shark": "Tiburón",
        "stingray": "Raya", "swordfish": "Pez espada", "seahorse": "Caballito de mar", "jellyfish": "Medusa",
        "starfish": "Estrella de mar", "crab": "Cangrejo", "lobster": "Langosta", "cephalopod": "Pulpo",
        "urchin": "Erizo de mar",
        // Insectos y otros
        "insect": "Insecto", "ant": "Hormiga", "bee": "Abeja", "butterfly": "Mariposa", "caterpillar": "Oruga",
        "dragonfly": "Libélula", "ladybug": "Mariquita", "moth": "Polilla", "spider": "Araña",
        "arachnid": "Araña", "scorpion": "Escorpión", "centipede": "Ciempiés", "millipede": "Milpiés",
        "snail": "Caracol", "worm": "Gusano", "scarab": "Escarabajo",
    ]

    /// Nombre de la capa a partir de las etiquetas (de más a menos segura). Entre las etiquetas casi
    /// igual de seguras, macOS pone primero la general ("animal") y después la concreta ("cebra"):
    /// se elige la más concreta que tenga nombre en español. Si macOS no está razonablemente seguro, no se
    /// pone nombre (mejor «Animal» que un nombre equivocado).
    static func name(for labels: [(identifier: String, confidence: Float)], in table: [String: String]) -> String? {
        guard let top = labels.first?.confidence, top > 0 else { return nil }
        let minimum = max(0.15, top * 0.5)
        var remaining = labels.filter { $0.confidence >= minimum }[...]
        while let first = remaining.first {
            let tied = remaining.prefix { first.confidence - $0.confidence < 0.01 }
            if let found = tied.reversed().lazy.compactMap({ table[$0.identifier] }).first { return found }
            remaining = remaining.dropFirst(tied.count)
        }
        return nil
    }
}
