const argon2 = require("argon2");

(async () => {
    const hash = await argon2.hash("MySecurePassword123!", {
        type: argon2.argon2id,
        memoryCost: 65540,
        timeCost: 3,
        parallelism: 4,
    });

    console.log(hash);
})();